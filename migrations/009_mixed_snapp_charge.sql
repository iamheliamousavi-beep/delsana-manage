-- ===========================================================================
-- 009_mixed_snapp_charge.sql
--
-- Mixed payment fix: the Snapp part S is the customer's real Snapp charge
-- (never multiplied). The Snapp fee is paid in cash.
--
-- BEFORE running: export all orders as CSV from the app.
-- Every statement below is idempotent and safe to run twice.
-- Mirrored into setup.sql (fresh installs already contain the end state).
--
--   1. New columns `snapp_fee`, `snapp_deposit` (NOT NULL DEFAULT 0).
--   2. Backfill without ever changing total/payout/owe/h_share:
--      cash -> fee 0, deposit 0; snapp -> fee 0, deposit payout;
--      legacy mixed (stored snapp_charge = snappRound(S)) ->
--        fee = total - payout, charge = part, cash = total - part,
--        deposit = part - fee. Abort if any row would violate invariants.
--   3. Replace old CHECK with the 4 invariants.
--   4. Rewrite pure `order_amounts` (now 13 OUTs incl. snapp_fee,
--      snapp_fee_clamped) and adapt `create_order` INSERT.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1) new columns
-- ---------------------------------------------------------------------------
alter table public.orders
  add column if not exists snapp_fee bigint not null default 0,
  add column if not exists snapp_deposit bigint not null default 0;

-- ---------------------------------------------------------------------------
-- 2) backfill (no-op on re-run for rows that already comply)
-- ---------------------------------------------------------------------------
-- cash rows
update public.orders set snapp_fee = 0, snapp_deposit = 0
 where method = 'cash' and (snapp_fee <> 0 or snapp_deposit <> 0);

-- snapp rows
update public.orders set snapp_fee = 0, snapp_deposit = payout
 where method = 'snapp' and (snapp_fee <> 0 or snapp_deposit <> payout);

-- legacy mixed rows (old model stored snapp_charge = snappRound(S))
update public.orders
   set snapp_fee = total - payout,
       snapp_charge = snapp_part,
       cash_charge = total - snapp_part,
       snapp_deposit = snapp_part - (total - payout)
 where method = 'mixed' and snapp_charge <> snapp_part;

-- verify every legacy mixed row now satisfies all 4 invariants; abort otherwise
do $$
declare
  v_bad integer;
begin
  select count(*) into v_bad from public.orders
   where method = 'mixed'
     and not (snapp_charge + cash_charge = total
              and snapp_deposit + cash_charge = payout
              and owe + h_share = payout
              and snapp_charge = snapp_part
              and snapp_deposit = snapp_part - snapp_fee
              and total = payout + snapp_fee
              and snapp_fee >= 0 and snapp_fee < snapp_part);
  if v_bad > 0 then
    raise exception 'migration 009: % legacy mixed rows violate invariants', v_bad;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3) constraints: drop old, add the 4 invariants
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_constraint where conname = 'orders_mixed_amounts_check') then
    alter table public.orders drop constraint orders_mixed_amounts_check;
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'orders_amounts_invariants_check') then
    alter table public.orders add constraint orders_amounts_invariants_check
      check (snapp_charge + cash_charge = total
             and snapp_deposit + cash_charge = payout
             and owe + h_share = payout
             and ((method = 'mixed') = (snapp_part > 0))
             and (method <> 'mixed' or (snapp_charge = snapp_part
                                        and snapp_deposit = snapp_part - snapp_fee
                                        and total = payout + snapp_fee))
             and snapp_fee >= 0
             and snapp_deposit >= 0
             and (method = 'mixed' or snapp_fee = 0));
  end if;
exception when others then
  raise warning 'orders invariants check not added: %', sqlerrm;
end $$;

-- ---------------------------------------------------------------------------
-- 4) order_amounts: the single server-side money implementation (new model)
-- ---------------------------------------------------------------------------
-- OUT list grows 11 -> 13, so the old function must be dropped first
-- (CREATE OR REPLACE cannot change a return type).
drop function if exists public.order_amounts(
  bigint, bigint, bigint, bigint, text, bigint, text, bigint, numeric, bigint);

create or replace function public.order_amounts(
  p_sub bigint, p_base_sum bigint, p_hp_sum bigint,
  p_discount bigint, p_bearer text, p_ship_fee bigint,
  p_method text, p_snapp_part bigint, p_mult numeric, p_step bigint,
  out o_net bigint, out o_mahdi_disc bigint, out o_helia_disc bigint,
  out o_total bigint, out o_payout bigint, out o_owe bigint,
  out o_h_share bigint, out o_snapp_part bigint,
  out o_snapp_charge bigint, out o_cash_charge bigint,
  out o_snapp_deposit bigint, out o_snapp_fee bigint,
  out o_snapp_fee_clamped boolean
)
language plpgsql
immutable
set search_path = public
as $$
declare
  v_bearer text := coalesce(p_bearer, 'helia');
  v_net    bigint;
  v_total  bigint;
  v_payout bigint;
  v_rounded bigint;
  v_fee    bigint;
  v_clamped boolean := false;
begin
  if p_sub is null or p_base_sum is null or p_hp_sum is null or p_ship_fee is null then
    raise exception 'خطای محاسباتی: ورودی نامعتبر است';
  end if;
  if p_method not in ('cash', 'snapp', 'mixed') then
    raise exception 'روش پرداخت نامعتبر است';
  end if;
  if v_bearer not in ('helia', 'mahdi', 'split') then
    raise exception 'طرف تخفیف نامعتبر است';
  end if;
  if p_discount is null or p_discount < 0 then
    raise exception 'تخفیف نمی‌تواند منفی باشد';
  end if;
  if p_discount > p_sub then
    raise exception 'تخفیف از مبلغ کالاها بیشتر است';
  end if;

  -- discount split (same rules as calc.js; split gives mahdi floor(D/2))
  if v_bearer = 'helia' then
    o_mahdi_disc := 0;             o_helia_disc := p_discount;
  elsif v_bearer = 'mahdi' then
    o_mahdi_disc := p_discount;    o_helia_disc := 0;
  else
    o_mahdi_disc := p_discount / 2;            -- integer division = floor
    o_helia_disc := p_discount - o_mahdi_disc;
  end if;

  v_net := p_sub - p_discount;
  o_net := v_net;
  v_payout := v_net + p_ship_fee;
  o_payout := v_payout;

  o_snapp_part := 0;
  o_snapp_charge := 0;
  o_cash_charge := 0;
  o_snapp_deposit := 0;
  o_snapp_fee := 0;
  o_snapp_fee_clamped := false;

  if p_method = 'mixed' then
    if p_snapp_part is null or p_snapp_part < 1 then
      raise exception 'مبلغ اسنپ‌پی باید عدد صحیح و حداقل ۱ باشد';
    end if;
    if p_snapp_part >= v_net then
      raise exception 'مبلغ اسنپ‌پی باید کمتر از مبلغ کالاها پس از تخفیف باشد؛ برای پرداخت کامل از روش اسنپ‌پی یا نقدی استفاده کنید';
    end if;
    if p_mult is null or p_mult <= 0 or p_mult > 10 then
      raise exception 'ضریب اسنپ‌پی نامعتبر است';
    end if;
    if p_step is null or p_step <= 0 then
      raise exception 'تنظیمات نامعتبر است';
    end if;
    v_rounded := public.round_to_step(p_snapp_part * p_mult, p_step);
    if v_rounded < p_snapp_part then
      v_fee := 0;
      v_clamped := true;
    else
      v_fee := v_rounded - p_snapp_part;
      v_clamped := false;
    end if;
    if not (v_fee < p_snapp_part) then
      raise exception 'کارمزد اسنپ‌پی از مبلغ اسنپ‌پی بیشتر می‌شود؛ ضریب را بررسی کنید';
    end if;
    o_snapp_part := p_snapp_part;
    o_snapp_fee := v_fee;
    o_snapp_fee_clamped := v_clamped;
    o_snapp_charge := p_snapp_part;
    o_snapp_deposit := p_snapp_part - v_fee;
    o_cash_charge := (v_net - p_snapp_part) + v_fee + p_ship_fee;
    v_total := o_snapp_charge + o_cash_charge;
  elsif p_method = 'snapp' then
    if p_snapp_part is not null and p_snapp_part <> 0 then
      raise exception 'مبلغ اسنپ‌پی فقط برای پرداخت ترکیبی است';
    end if;
    if p_mult is null or p_mult <= 0 then
      raise exception 'ضریب اسنپ‌پی نامعتبر است';
    end if;
    if p_step is null or p_step <= 0 then
      raise exception 'تنظیمات نامعتبر است';
    end if;
    v_total := public.round_to_step(v_net * p_mult, p_step) + p_ship_fee;
    o_snapp_charge := v_total;
    o_snapp_deposit := v_payout;
    o_snapp_fee := 0;
    o_snapp_fee_clamped := false;
  else
    if p_snapp_part is not null and p_snapp_part <> 0 then
      raise exception 'مبلغ اسنپ‌پی فقط برای پرداخت ترکیبی است';
    end if;
    v_total := v_net + p_ship_fee;
    o_cash_charge := v_total;
    o_snapp_deposit := 0;
    o_snapp_fee := 0;
    o_snapp_fee_clamped := false;
  end if;
  o_total := v_total;

  if p_base_sum - o_mahdi_disc < 0 then
    raise exception 'تخفیف بر عهده مغازه از مبلغ کالاهای مغازه بیشتر است';
  end if;
  o_owe := (p_base_sum - o_mahdi_disc) + p_ship_fee;
  o_h_share := p_hp_sum - o_helia_disc;

  -- all four invariants hold for every method
  if (o_owe + o_h_share) <> v_payout
     or (o_snapp_charge + o_cash_charge) <> v_total
     or (o_snapp_deposit + o_cash_charge) <> v_payout
     or (p_method = 'mixed' and v_total <> v_payout + o_snapp_fee) then
    raise exception 'خطای محاسباتی: سهم‌ها با پرداختی برابر نیستند';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5) create_order: store snapp_fee + snapp_deposit (signature unchanged)
-- ---------------------------------------------------------------------------
create or replace function public.create_order(
  p_items            jsonb,
  p_customer         text,
  p_phone            text,
  p_address          text,
  p_postal_code      text,
  p_shipping_method  text,
  p_method           text,
  p_discount         bigint   default 0,
  p_discount_bearer  text     default 'helia',
  p_snapp_multiplier numeric  default null,
  p_note             text     default null,
  p_status           text     default null,
  p_snapp_part       bigint   default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid          uuid := auth.uid();
  v_postal       text;
  v_items        jsonb;
  v_sub          bigint := 0;
  v_base_sum     bigint := 0;
  v_hp_sum       bigint := 0;
  v_discount     bigint := coalesce(p_discount, 0);
  v_ship_fee     bigint;
  v_mahdi_disc   bigint;
  v_helia_disc   bigint;
  v_total        bigint;
  v_payout       bigint;
  v_owe          bigint;
  v_h_share      bigint;
  v_snapp_part   bigint;
  v_snapp_charge bigint;
  v_cash_charge  bigint;
  v_snapp_deposit bigint;
  v_snapp_fee    bigint;
  v_post_fee     bigint;
  v_mult         numeric;
  v_step         bigint;
  v_raw          text;
  v_status       text;
  v_order_id     uuid;
  v_out_items    jsonb := '[]'::jsonb;
  v_expected     integer := 0;
  v_seen         integer := 0;
  v_hist         jsonb;
  rec            record;
  v_qty          integer;
begin
  if v_uid is null then raise exception 'ابتدا وارد شوید'; end if;
  if not public.is_member() then
    raise exception 'پروفایل شما یافت نشد';
  end if;

  if p_shipping_method not in ('post', 'courier') then
    raise exception 'روش ارسال نامعتبر است';
  end if;
  if p_method not in ('cash', 'snapp', 'mixed') then
    raise exception 'روش پرداخت نامعتبر است';
  end if;
  if coalesce(p_discount_bearer, 'helia') not in ('helia', 'mahdi', 'split') then
    raise exception 'طرف تخفیف نامعتبر است';
  end if;
  if v_discount is null or v_discount < 0 then
    raise exception 'تخفیف نمی‌تواند منفی باشد';
  end if;

  if char_length(trim(coalesce(p_customer, ''))) = 0 then
    raise exception 'نام مشتری اجباری است';
  end if;
  v_postal := regexp_replace(public.normalize_digits(coalesce(p_postal_code, '')), '[^0-9]', '', 'g');
  if char_length(v_postal) <> 10 then
    raise exception 'کد پستی باید دقیقاً ۱۰ رقم باشد';
  end if;
  if char_length(trim(coalesce(p_address, ''))) = 0 then
    raise exception 'آدرس اجباری است';
  end if;
  if char_length(trim(public.normalize_digits(coalesce(p_phone, '')))) < 10 then
    raise exception 'شماره تماس معتبر نیست';
  end if;
  if coalesce(p_note, '') <> '' and char_length(p_note) > 1000 then
    raise exception 'یادداشت خیلی بلند است';
  end if;

  v_raw := null;
  select value into v_raw from public.settings where key = 'post_fee';
  if v_raw is null then
    v_post_fee := 190000;
  elsif v_raw !~ '^[0-9]{1,15}$' then
    raise exception 'تنظیمات نامعتبر است';
  else
    v_post_fee := v_raw::bigint;
  end if;

  v_raw := null;
  select value into v_raw from public.settings where key = 'snapp_multiplier';
  if v_raw is null then
    v_mult := 1.15;
  elsif v_raw !~ '^[0-9]+(\.[0-9]+)?$' then
    raise exception 'تنظیمات نامعتبر است';
  else
    v_mult := v_raw::numeric;
    if v_mult <= 0 then raise exception 'تنظیمات نامعتبر است'; end if;
  end if;

  v_raw := null;
  select value into v_raw from public.settings where key = 'rounding_step';
  if v_raw is null then
    v_step := 5000;
  elsif v_raw !~ '^[0-9]{1,15}$' then
    raise exception 'تنظیمات نامعتبر است';
  else
    v_step := v_raw::bigint;
    if v_step <= 0 then raise exception 'تنظیمات نامعتبر است'; end if;
  end if;

  if p_method = 'snapp' or p_method = 'mixed' then
    if p_snapp_multiplier is not null then
      if p_snapp_multiplier <= 0 or p_snapp_multiplier > 10 then
        raise exception 'ضریب اسنپ‌پی نامعتبر است';
      end if;
      v_mult := p_snapp_multiplier;
    end if;
    v_status := 'awaiting_snapp';
  else
    v_status := coalesce(p_status, 'new');
    if v_status not in ('new', 'paid') then
      raise exception 'وضعیت اولیه برای سفارش نقدی باید new یا paid باشد';
    end if;
  end if;

  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'حداقل یک کالا انتخاب کنید';
  end if;

  if exists (
    select 1 from jsonb_array_elements(p_items) as e
     where coalesce(e->>'product_id', '')
             !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        or coalesce(public.normalize_digits(e->>'qty'), '') !~ '^[1-9][0-9]{0,5}$'
  ) then
    raise exception 'اطلاعات کالاهای سفارش نامعتبر است';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('product_id', pid, 'qty', qty)
                            order by pid), '[]'::jsonb)
    into v_items
  from (
    select e->>'product_id' as pid,
           sum(public.normalize_digits(e->>'qty')::integer) as qty
      from jsonb_array_elements(p_items) as e
     group by 1
  ) t;

  v_expected := jsonb_array_length(v_items);
  v_seen     := 0;

  for rec in
    select p.id, p.name, p.base_price, p.hp, p.archived, p.available,
           (e->>'qty')::integer as qty
      from jsonb_array_elements(v_items) as e
      join public.products p on p.id = (e->>'product_id')::uuid
     order by p.id
     for update of p
  loop
    v_seen := v_seen + 1;
    v_qty  := rec.qty;
    if v_qty is null or v_qty < 1 then
      raise exception 'تعداد کالا نامعتبر است';
    end if;
    if rec.archived then
      raise exception 'محصول «%» بایگانی شده است', rec.name;
    end if;
    if not rec.available then
      raise exception 'محصول «%» ناموجود است', rec.name;
    end if;

    v_sub      := v_sub + v_qty * (rec.base_price + rec.hp);
    v_base_sum := v_base_sum + v_qty * rec.base_price;
    v_hp_sum   := v_hp_sum + v_qty * rec.hp;

    v_out_items := v_out_items || jsonb_build_array(jsonb_build_object(
      'product_id', rec.id, 'name', rec.name, 'qty', v_qty,
      'base', rec.base_price, 'hp', rec.hp));
  end loop;

  if v_seen <> v_expected then
    raise exception 'یکی از محصولات انتخاب‌شده وجود ندارد';
  end if;

  if v_discount > v_sub then
    raise exception 'تخفیف از مبلغ کالاها بیشتر است';
  end if;

  v_ship_fee := case when p_shipping_method = 'post' then v_post_fee else 0 end;

  select a.o_mahdi_disc, a.o_helia_disc, a.o_total, a.o_payout, a.o_owe,
         a.o_h_share, a.o_snapp_part, a.o_snapp_charge, a.o_cash_charge,
         a.o_snapp_deposit, a.o_snapp_fee
    into v_mahdi_disc, v_helia_disc, v_total, v_payout, v_owe,
         v_h_share, v_snapp_part, v_snapp_charge, v_cash_charge,
         v_snapp_deposit, v_snapp_fee
    from public.order_amounts(
           v_sub, v_base_sum, v_hp_sum, v_discount, p_discount_bearer,
           v_ship_fee, p_method, p_snapp_part, v_mult, v_step) as a;

  if v_h_share < 0 then
    raise notice 'هشدار: سود پیج منفی می‌شود؛ تخفیف را کم کنید';
  end if;

  v_hist := jsonb_build_array(jsonb_build_object(
    'status', v_status, 'at', now(), 'by', v_uid));

  insert into public.orders (
    customer, phone, address, postal_code, items, method, shipping_method,
    shipping_fee, snapp_multiplier, rounding_step, discount, discount_bearer,
    mahdi_discount, helia_discount, total, owe, h_share, payout,
    status, status_history, note, last_actor,
    snapp_part, snapp_charge, cash_charge, snapp_fee, snapp_deposit
  ) values (
    trim(p_customer), trim(public.normalize_digits(p_phone)), trim(p_address), v_postal,
    v_out_items, p_method, p_shipping_method, v_ship_fee, v_mult, v_step,
    v_discount, p_discount_bearer, v_mahdi_disc, v_helia_disc,
    v_total, v_owe, v_h_share, v_payout, v_status, v_hist, coalesce(p_note, ''),
    v_uid, v_snapp_part, v_snapp_charge, v_cash_charge, v_snapp_fee, v_snapp_deposit
  ) returning id into v_order_id;

  return v_order_id;
end;
$$;

revoke all on function
  public.create_order(jsonb, text, text, text, text, text, text, bigint, text, numeric, text, text, bigint)
  from PUBLIC, anon, authenticated;
grant execute on function
  public.create_order(jsonb, text, text, text, text, text, text, bigint, text, numeric, text, text, bigint)
  to authenticated, service_role;

-- order_amounts is pure; keep it callable but never from anon
do $$
declare
  f record;
begin
  for f in
    select p.oid, pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'order_amounts'
  loop
    execute format('revoke all on function public.order_amounts(%s) from PUBLIC, anon, authenticated', f.args);
    execute format('grant execute on function public.order_amounts(%s) to authenticated, service_role', f.args);
  end loop;
end $$;

do $$
declare
  v_count integer;
begin
  select count(*) into v_count from pg_proc where proname = 'create_order';
  if v_count <> 1 then
    raise warning 'expected exactly 1 create_order, found %', v_count;
  end if;
end $$;

notify pgrst, 'reload schema';
