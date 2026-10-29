-- ===========================================================================
-- 011_split_shipping_payment.sql
--
-- Split payment: the goods amount and the shipping fee may be paid through
-- different methods. The existing `method` column keeps its meaning (how the
-- goods are paid); the new `shipping_payment_method` stores how the shipping
-- fee is paid (cash / Snapp).
--
-- Old rows are backfilled to exactly their previous behaviour:
--   method cash  -> shipping cash
--   method snapp -> shipping snapp
--   method mixed -> shipping cash (shipping was always cash in mixed)
-- No total/payout/owe/h_share changes. Idempotent and safe to run twice.
--
-- Run BEFORE pushing the frontend (the orders query selects the new column).
-- Back up with the app's CSV export first.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1) column, backfill, constraint
-- ---------------------------------------------------------------------------
alter table public.orders
  add column if not exists shipping_payment_method text;

update public.orders
   set shipping_payment_method = case
         when method = 'mixed' then 'cash'
         else method
       end
 where shipping_payment_method is null;

alter table public.orders
  alter column shipping_payment_method set default 'cash';

alter table public.orders
  alter column shipping_payment_method set not null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'orders_shipping_payment_method_check') then
    alter table public.orders add constraint orders_shipping_payment_method_check
      check (shipping_payment_method in ('cash', 'snapp'));
  end if;
end $$;

-- The mixed-payment invariant used to pin `snapp_charge = snapp_part` and
-- `snapp_deposit = snapp_part - snapp_fee`; with shipping paid through Snapp
-- both include the shipping fee, so the constraint must be re-created.
alter table public.orders drop constraint if exists orders_amounts_invariants_check;
alter table public.orders add constraint orders_amounts_invariants_check
  check (snapp_charge + cash_charge = total
         and snapp_deposit + cash_charge = payout
         and owe + h_share = payout
         and ((method = 'mixed') = (snapp_part > 0))
         and (method <> 'mixed' or (snapp_charge = snapp_part
                                    + (case when shipping_payment_method = 'snapp' then shipping_fee else 0 end)
                                    and snapp_deposit = snapp_part - snapp_fee
                                    + (case when shipping_payment_method = 'snapp' then shipping_fee else 0 end)
                                    and total = payout + snapp_fee))
         and snapp_fee >= 0
         and snapp_deposit >= 0
         and (method = 'mixed' or snapp_fee = 0));

-- ---------------------------------------------------------------------------
-- 2) order_amounts: add the shipping-payment argument (last position)
--    The old 10-argument signature must be dropped first.
-- ---------------------------------------------------------------------------
drop function if exists public.order_amounts(
  bigint, bigint, bigint, bigint, text, bigint, text, bigint, numeric, bigint);

create or replace function public.order_amounts(
  p_sub bigint, p_base_sum bigint, p_hp_sum bigint,
  p_discount bigint, p_bearer text, p_ship_fee bigint,
  p_method text, p_snapp_part bigint, p_mult numeric, p_step bigint,
  p_shipping_payment_method text default 'cash',
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
  v_ship_pay text;
  v_ship_snap bigint;
begin
  if p_sub is null or p_base_sum is null or p_hp_sum is null or p_ship_fee is null then
    raise exception 'خطای محاسباتی: ورودی نامعتبر است';
  end if;
  if p_method not in ('cash', 'snapp', 'mixed') then
    raise exception 'روش پرداخت نامعتبر است';
  end if;
  -- old callers / old rows: shipping follows the goods method, mixed -> cash
  v_ship_pay := coalesce(nullif(trim(p_shipping_payment_method), ''),
                         case when p_method = 'mixed' then 'cash' else p_method end);
  if v_ship_pay not in ('cash', 'snapp') then
    raise exception 'روش پرداخت هزینه ارسال نامعتبر است';
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
  -- the shipping fee is never multiplied; it is routed as-is
  v_ship_snap := case when v_ship_pay = 'snapp' then p_ship_fee else 0 end;

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
    o_snapp_charge := p_snapp_part + v_ship_snap;
    o_snapp_deposit := (p_snapp_part - v_fee) + v_ship_snap;
    o_cash_charge := (v_net - p_snapp_part) + v_fee + (p_ship_fee - v_ship_snap);
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
    v_rounded := public.round_to_step(v_net * p_mult, p_step);
    v_total := v_rounded + p_ship_fee;
    o_snapp_charge := v_rounded + v_ship_snap;
    o_cash_charge := p_ship_fee - v_ship_snap;
    o_snapp_deposit := v_net + v_ship_snap;
    o_snapp_fee := 0;
    o_snapp_fee_clamped := false;
  else
    if p_snapp_part is not null and p_snapp_part <> 0 then
      raise exception 'مبلغ اسنپ‌پی فقط برای پرداخت ترکیبی است';
    end if;
    v_total := v_net + p_ship_fee;
    o_snapp_charge := v_ship_snap;
    o_cash_charge := v_net + (p_ship_fee - v_ship_snap);
    o_snapp_deposit := v_ship_snap;
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
-- 3) create_order: one new trailing defaulted argument keeps old 13-arg
--    RPC calls working (they fall back to "shipping follows goods").
-- ---------------------------------------------------------------------------
drop function if exists public.create_order(
  jsonb, text, text, text, text, text, text, bigint, text, numeric, text, text, bigint);

create or replace function public.create_order(
  p_items            jsonb,             -- [{"product_id": "...", "qty": 2}]
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
  p_snapp_part       bigint   default null,
  p_shipping_payment_method text default null
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
  v_ship_pay     text;
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

  -- ---------- validate enums -------------------------------------------
  if p_shipping_method not in ('post', 'courier') then
    raise exception 'روش ارسال نامعتبر است';
  end if;
  if p_method not in ('cash', 'snapp', 'mixed') then
    raise exception 'روش پرداخت نامعتبر است';
  end if;
  -- old clients send null: shipping follows the goods method (mixed -> cash)
  v_ship_pay := coalesce(nullif(trim(p_shipping_payment_method), ''),
                         case when p_method = 'mixed' then 'cash' else p_method end);
  if v_ship_pay not in ('cash', 'snapp') then
    raise exception 'روش پرداخت هزینه ارسال نامعتبر است';
  end if;
  if coalesce(p_discount_bearer, 'helia') not in ('helia', 'mahdi', 'split') then
    raise exception 'طرف تخفیف نامعتبر است';
  end if;
  if v_discount is null or v_discount < 0 then
    raise exception 'تخفیف نمی‌تواند منفی باشد';
  end if;

  -- ---------- validate customer data ------------------------------------
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

  -- ---------- settings snapshot (defensive, section 5.5) ----------------
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
  end if;
  -- any Snapp-paid part (goods or shipping) waits for Snapp settlement
  if p_method = 'snapp' or p_method = 'mixed' or v_ship_pay = 'snapp' then
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

  -- ---------- validate item payload -------------------------------------
  if exists (
    select 1 from jsonb_array_elements(p_items) as e
     where coalesce(e->>'product_id', '')
             !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        or coalesce(public.normalize_digits(e->>'qty'), '') !~ '^[1-9][0-9]{0,5}$'
  ) then
    raise exception 'اطلاعات کالاهای سفارش نامعتبر است';
  end if;

  -- merge duplicate lines of the same product (sorted by id for stable locking)
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

  -- ---------- lock products, read prices --------------------------------
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

    -- line snapshot stored on the order
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

  -- ---------- amounts: the single server-side implementation ------------
  select a.o_mahdi_disc, a.o_helia_disc, a.o_total, a.o_payout, a.o_owe,
         a.o_h_share, a.o_snapp_part, a.o_snapp_charge, a.o_cash_charge,
         a.o_snapp_deposit, a.o_snapp_fee
    into v_mahdi_disc, v_helia_disc, v_total, v_payout, v_owe,
         v_h_share, v_snapp_part, v_snapp_charge, v_cash_charge,
         v_snapp_deposit, v_snapp_fee
    from public.order_amounts(
           v_sub, v_base_sum, v_hp_sum, v_discount, p_discount_bearer,
           v_ship_fee, p_method, p_snapp_part, v_mult, v_step, v_ship_pay) as a;

  if v_h_share < 0 then
    raise notice 'هشدار: سود پیج منفی می‌شود؛ تخفیف را کم کنید';
  end if;

  v_hist := jsonb_build_array(jsonb_build_object(
    'status', v_status, 'at', now(), 'by', v_uid));

  -- ---------- insert the order (atomic: one statement, one transaction) --
  insert into public.orders (
    customer, phone, address, postal_code, items, method, shipping_method,
    shipping_payment_method, shipping_fee, snapp_multiplier, rounding_step,
    discount, discount_bearer, mahdi_discount, helia_discount, total, owe,
    h_share, payout, status, status_history, note, last_actor,
    snapp_part, snapp_charge, cash_charge, snapp_fee, snapp_deposit
  ) values (
    trim(p_customer), trim(public.normalize_digits(p_phone)), trim(p_address), v_postal,
    v_out_items, p_method, p_shipping_method, v_ship_pay, v_ship_fee, v_mult, v_step,
    v_discount, p_discount_bearer, v_mahdi_disc, v_helia_disc,
    v_total, v_owe, v_h_share, v_payout, v_status, v_hist, coalesce(p_note, ''),
    v_uid, v_snapp_part, v_snapp_charge, v_cash_charge, v_snapp_fee, v_snapp_deposit
  ) returning id into v_order_id;

  return v_order_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4) admin_update_order: allow the new field, recompute and persist it
-- ---------------------------------------------------------------------------
create or replace function public.admin_update_order(p_order_id uuid, p_data jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  o record;
  v_customer text; v_phone text; v_address text; v_postal text; v_note text;
  v_ship text; v_method text; v_ship_pay text; v_snapp_part bigint; v_discount bigint;
  v_bearer text; v_tracking text; v_status text;
  v_post_fee bigint; v_mult numeric; v_step bigint;
  v_set text;
  v_ship_fee bigint;
  v_sub bigint := 0; v_base_sum bigint := 0; v_hp_sum bigint := 0;
  v_out_items jsonb := '[]'::jsonb;
  v_mahdi_disc bigint; v_helia_disc bigint; v_total bigint; v_payout bigint;
  v_owe bigint; v_h_share bigint; v_sp bigint; v_sc bigint; v_cc bigint;
  v_dep bigint; v_fee bigint;
  v_hist jsonb;
  v_after jsonb;
  v_changed text[] := '{}';
  v_key text;
  v_allowed text[] := array['customer','phone','address','postal_code','note',
    'shipping_method','shipping_payment_method','method','snapp_part','discount','discount_bearer',
    'tracking','status','shipping_fee','snapp_multiplier','rounding_step','items'];
  e jsonb; v_name text; v_qty bigint; v_base bigint; v_hp bigint; v_pid text;
  it jsonb;
begin
  if not public.is_admin() then
    raise exception 'دسترسی غیرمجاز';
  end if;
  if p_data is null or jsonb_typeof(p_data) <> 'object' then
    raise exception 'فیلد نامعتبر';
  end if;
  for v_key in select jsonb_object_keys(p_data) loop
    if not (v_key = any(v_allowed)) then
      raise exception 'فیلد نامعتبر';
    end if;
  end loop;

  select * into o from public.orders where id = p_order_id for update;
  if not found then raise exception 'سفارش پیدا نشد'; end if;

  -- ---------- merge the patch over stored values -------------------------
  v_customer := case when p_data ? 'customer' then trim(p_data->>'customer') else o.customer end;
  v_phone    := case when p_data ? 'phone' then trim(public.normalize_digits(p_data->>'phone')) else o.phone end;
  v_address  := case when p_data ? 'address' then trim(p_data->>'address') else o.address end;
  v_postal   := case when p_data ? 'postal_code'
                     then regexp_replace(public.normalize_digits(p_data->>'postal_code'), '[^0-9]', '', 'g')
                     else o.postal_code end;
  v_note     := case when p_data ? 'note' then coalesce(p_data->>'note', '') else o.note end;
  v_ship     := case when p_data ? 'shipping_method' then p_data->>'shipping_method' else o.shipping_method end;
  v_method   := case when p_data ? 'method' then p_data->>'method' else o.method end;
  v_ship_pay := case when p_data ? 'shipping_payment_method'
                     then nullif(trim(coalesce(p_data->>'shipping_payment_method', '')), '')
                     else coalesce(o.shipping_payment_method,
                                   case when o.method = 'mixed' then 'cash' else o.method end)
                end;
  v_snapp_part := case when p_data ? 'snapp_part'
                       then (case when p_data->>'snapp_part' is null then null else (p_data->>'snapp_part')::bigint end)
                       else o.snapp_part end;
  v_discount := case when p_data ? 'discount' then (p_data->>'discount')::bigint else o.discount end;
  v_bearer   := case when p_data ? 'discount_bearer' then coalesce(p_data->>'discount_bearer', 'helia') else o.discount_bearer end;
  v_tracking := case when p_data ? 'tracking'
                     then left(trim(coalesce(p_data->>'tracking', '')), 60)
                     else o.tracking end;
  v_status   := case when p_data ? 'status' then p_data->>'status' else o.status end;

  -- settings snapshot overrides: keep the order's own snapshot by default.
  -- (courier orders store shipping_fee 0, so switching courier -> post with
  -- no override falls back to the current global post_fee; see Assumptions.)
  if p_data ? 'shipping_fee' then
    v_post_fee := (p_data->>'shipping_fee')::bigint;
    if v_post_fee is null or v_post_fee < 0 then raise exception 'تنظیمات نامعتبر است'; end if;
  elsif o.shipping_method = 'post' then
    v_post_fee := o.shipping_fee;
  else
    select value into v_set from public.settings where key = 'post_fee';
    if v_set is null or v_set !~ '^[0-9]{1,15}$' then v_set := '190000'; end if;
    v_post_fee := v_set::bigint;
  end if;
  if p_data ? 'snapp_multiplier' then
    v_mult := (p_data->>'snapp_multiplier')::numeric;
  else
    v_mult := o.snapp_multiplier;
  end if;
  if p_data ? 'rounding_step' then
    v_step := (p_data->>'rounding_step')::bigint;
  else
    v_step := o.rounding_step;
  end if;
  if v_mult is null or v_mult <= 0 or v_mult > 10 then raise exception 'ضریب اسنپ‌پی نامعتبر است'; end if;
  if v_step is null or v_step <= 0 then raise exception 'تنظیمات نامعتبر است'; end if;

  -- ---------- validate ----------------------------------------------------
  if char_length(trim(coalesce(v_customer, ''))) = 0 then
    raise exception 'نام مشتری اجباری است';
  end if;
  if char_length(v_postal) <> 10 then
    raise exception 'کد پستی باید دقیقاً ۱۰ رقم باشد';
  end if;
  if char_length(trim(coalesce(v_address, ''))) = 0 then
    raise exception 'آدرس اجباری است';
  end if;
  if char_length(trim(v_phone)) < 10 then
    raise exception 'شماره تماس معتبر نیست';
  end if;
  if v_note <> '' and char_length(v_note) > 1000 then
    raise exception 'یادداشت خیلی بلند است';
  end if;
  if v_ship not in ('post', 'courier') then
    raise exception 'روش ارسال نامعتبر است';
  end if;
  if v_method not in ('cash', 'snapp', 'mixed') then
    raise exception 'روش پرداخت نامعتبر است';
  end if;
  if v_ship_pay is null then
    v_ship_pay := case when v_method = 'mixed' then 'cash' else v_method end;
  end if;
  if v_ship_pay not in ('cash', 'snapp') then
    raise exception 'روش پرداخت هزینه ارسال نامعتبر است';
  end if;
  if v_bearer not in ('helia', 'mahdi', 'split') then
    raise exception 'طرف تخفیف نامعتبر است';
  end if;
  if v_discount is null or v_discount < 0 then
    raise exception 'تخفیف نمی‌تواند منفی باشد';
  end if;
  if v_status not in ('new','awaiting_snapp','paid','settled','shipped','delivered','cancelled') then
    raise exception 'وضعیت نامعتبر است';
  end if;

  -- ---------- items --------------------------------------------------------
  if p_data ? 'items' then
    it := p_data->'items';
    if jsonb_typeof(it) <> 'array' or jsonb_array_length(it) = 0 then
      raise exception 'حداقل یک کالا انتخاب کنید';
    end if;
    for e in select value from jsonb_array_elements(it) loop
      v_name := trim(coalesce(e->>'name', ''));
      if char_length(v_name) = 0 then raise exception 'نام محصول اجباری است'; end if;
      begin
        v_qty := floor(coalesce(e->>'qty', '0')::numeric);
      exception when others then
        raise exception 'تعداد کالا نامعتبر است';
      end;
      begin
        v_base := floor(coalesce(e->>'base', '0')::numeric);
        v_hp   := floor(coalesce(e->>'hp', '0')::numeric);
      exception when others then
        raise exception 'قیمت نمی‌تواند منفی باشد';
      end;
      if v_qty is null or v_qty < 1 then raise exception 'تعداد کالا نامعتبر است'; end if;
      if v_base is null or v_base < 0 or v_hp is null or v_hp < 0 then
        raise exception 'قیمت نمی‌تواند منفی باشد';
      end if;
      v_pid := nullif(trim(coalesce(e->>'product_id', '')), '');
      if v_pid is not null and v_pid !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        raise exception 'اطلاعات کالاهای سفارش نامعتبر است';
      end if;
      v_sub      := v_sub + v_qty * (v_base + v_hp);
      v_base_sum := v_base_sum + v_qty * v_base;
      v_hp_sum   := v_hp_sum + v_qty * v_hp;
      v_out_items := v_out_items || jsonb_build_array(jsonb_build_object(
        'product_id', v_pid, 'name', v_name, 'qty', v_qty,
        'base', v_base, 'hp', v_hp));
    end loop;
  else
    -- keep the stored snapshot lines
    for e in select value from jsonb_array_elements(o.items) loop
      v_qty  := coalesce((e->>'qty')::bigint, 0);
      v_base := coalesce((e->>'base')::bigint, 0);
      v_hp   := coalesce((e->>'hp')::bigint, 0);
      v_sub      := v_sub + v_qty * (v_base + v_hp);
      v_base_sum := v_base_sum + v_qty * v_base;
      v_hp_sum   := v_hp_sum + v_qty * v_hp;
    end loop;
    v_out_items := o.items;
  end if;

  if v_discount > v_sub then
    raise exception 'تخفیف از مبلغ کالاها بیشتر است';
  end if;

  v_ship_fee := case when v_ship = 'post' then v_post_fee else 0 end;

  -- ---------- recompute ALL money through the single implementation -------
  select a.o_mahdi_disc, a.o_helia_disc, a.o_total, a.o_payout, a.o_owe,
         a.o_h_share, a.o_snapp_part, a.o_snapp_charge, a.o_cash_charge,
         a.o_snapp_deposit, a.o_snapp_fee
    into v_mahdi_disc, v_helia_disc, v_total, v_payout, v_owe,
         v_h_share, v_sp, v_sc, v_cc, v_dep, v_fee
    from public.order_amounts(
           v_sub, v_base_sum, v_hp_sum, v_discount, v_bearer,
           v_ship_fee, v_method, v_snapp_part, v_mult, v_step, v_ship_pay) as a;

  -- status_history: admin override bypasses the flow but is logged
  v_hist := o.status_history;
  if v_status is distinct from o.status then
    v_hist := v_hist || jsonb_build_array(jsonb_build_object(
      'status', v_status, 'at', now(), 'by', auth.uid(), 'note', 'تغییر توسط ادمین'));
  end if;

  -- ---------- write in ONE UPDATE ------------------------------------------
  update public.orders set
    customer = v_customer, phone = v_phone, address = v_address,
    postal_code = v_postal, note = v_note,
    items = v_out_items, method = v_method, shipping_method = v_ship,
    shipping_payment_method = v_ship_pay,
    shipping_fee = v_ship_fee, snapp_multiplier = v_mult, rounding_step = v_step,
    discount = v_discount, discount_bearer = v_bearer,
    mahdi_discount = v_mahdi_disc, helia_discount = v_helia_disc,
    total = v_total, owe = v_owe, h_share = v_h_share, payout = v_payout,
    snapp_part = v_sp, snapp_fee = v_fee, snapp_charge = v_sc,
    cash_charge = v_cc, snapp_deposit = v_dep,
    status = v_status, status_history = v_hist, tracking = v_tracking,
    last_actor = auth.uid()
   where id = p_order_id;
  select to_jsonb(x) into v_after from public.orders x where x.id = p_order_id;

  -- changed-field list: every patched key + every derived column that moved
  -- (array_append with an explicit cast: `arr || 'literal'` misresolves the
  -- unknown literal to text[] on some servers -> "malformed array literal")
  for v_key in select jsonb_object_keys(p_data) loop
    v_changed := array_append(v_changed, v_key);
  end loop;
  if (v_after->>'total')::bigint is distinct from o.total then v_changed := array_append(v_changed, 'total'::text); end if;
  if (v_after->>'payout')::bigint is distinct from o.payout then v_changed := array_append(v_changed, 'payout'::text); end if;
  if (v_after->>'owe')::bigint is distinct from o.owe then v_changed := array_append(v_changed, 'owe'::text); end if;
  if (v_after->>'h_share')::bigint is distinct from o.h_share then v_changed := array_append(v_changed, 'h_share'::text); end if;

  insert into public.audit_log (actor, entity, entity_id, action, before, after)
  values (auth.uid(), 'order', p_order_id, 'edit', to_jsonb(o), v_after);

  insert into public.outbox (kind, order_id, actor, payload)
  values ('order_edited', p_order_id, auth.uid(),
          jsonb_build_object('changed', to_jsonb(v_changed)));

  return p_order_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5) grants + schema cache
-- ---------------------------------------------------------------------------
revoke all on function public.order_amounts(
  bigint, bigint, bigint, bigint, text, bigint, text, bigint, numeric, bigint, text)
  from PUBLIC, anon, authenticated;
grant execute on function public.order_amounts(
  bigint, bigint, bigint, bigint, text, bigint, text, bigint, numeric, bigint, text)
  to authenticated, service_role;

revoke all on function public.create_order(
  jsonb, text, text, text, text, text, text, bigint, text, numeric, text, text, bigint, text)
  from PUBLIC, anon, authenticated;
grant execute on function public.create_order(
  jsonb, text, text, text, text, text, text, bigint, text, numeric, text, text, bigint, text)
  to authenticated, service_role;

notify pgrst, 'reload schema';
