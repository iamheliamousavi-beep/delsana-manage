-- ==========================================================================
-- Migration 002 — simplify the product model (master prompt section 3)
--
--   BEFORE running:
--     1. Export all orders as CSV from the app.
--     2. Run  select * from product_costs;
--        Run  select * from order_private;
--        and save the results — BOTH TABLES ARE DELETED below.
--
--   What changes:
--     * products gains `available`; `stock` is dropped (no stock tracking).
--     * products.base_price keeps its current value (it already equals the
--       old cost + mp) and becomes NOT NULL DEFAULT 0.
--     * product_costs / order_private and the base_price sync trigger are
--       dropped.  Cost, shop profit and order privacy no longer exist: both
--       partners see every number.
--     * All RPCs are recreated for the new model (section 3.2).
--
--   Old orders stay intact: orders.items already stores the
--   {product_id, name, qty, base, hp} snapshot each line was sold at.
--
-- IDEMPOTENT — safe to run more than once.
-- ==========================================================================

-- --------------------------------------------------------------------------
-- 1) availability flag
-- --------------------------------------------------------------------------
alter table public.products
  add column if not exists available boolean not null default true;

-- --------------------------------------------------------------------------
-- 2) base_price: keep the value, enforce NOT NULL DEFAULT 0
-- --------------------------------------------------------------------------
update public.products set base_price = 0 where base_price is null;
alter table public.products alter column base_price set default 0;
alter table public.products alter column base_price set not null;

-- --------------------------------------------------------------------------
-- 3) last_actor — required by create_order (section 3.2).  Migration 003 adds
--    the notification columns and repeats this clause with `if not exists`.
-- --------------------------------------------------------------------------
alter table public.orders
  add column if not exists last_actor uuid;

-- --------------------------------------------------------------------------
-- 4) drop the base_price sync trigger fed by product_costs
-- --------------------------------------------------------------------------
drop trigger if exists trg_sync_base_price on public.product_costs;
drop function if exists public.sync_base_price();

-- --------------------------------------------------------------------------
-- 5) drop the removed tables
-- --------------------------------------------------------------------------
drop table if exists public.order_private cascade;
drop table if exists public.product_costs cascade;

-- --------------------------------------------------------------------------
-- 6) stock column and stock-only RPCs
-- --------------------------------------------------------------------------
alter table public.products drop column if exists stock;

drop function if exists public.set_cost(uuid, bigint, bigint);
drop function if exists public.bulk_cost_update(uuid[], text, numeric);
-- old signatures, replaced below
drop function if exists public.add_product(text, integer, bigint, bigint, bigint);
drop function if exists public.update_product(uuid, text, integer, boolean);

-- ==========================================================================
--  RPC: products (section 3.2) — every function requires is_member()
--        (or is_mahdi() where the specification says "shop only")
-- ==========================================================================

create or replace function public.add_product(
  p_name       text,
  p_base_price bigint,
  p_hp         bigint,
  p_available  boolean default true
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if not public.is_mahdi() then
    raise exception 'دسترسی غیرمجاز';
  end if;
  if char_length(trim(coalesce(p_name, ''))) = 0 then
    raise exception 'نام محصول اجباری است';
  end if;
  if coalesce(p_base_price, 0) < 0 or coalesce(p_hp, 0) < 0 then
    raise exception 'قیمت نمی‌تواند منفی باشد';
  end if;

  insert into public.products (name, base_price, hp, available)
  values (trim(p_name), p_base_price, p_hp, coalesce(p_available, true))
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.update_product(
  p_id       uuid,
  p_name     text,
  p_archived boolean
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_mahdi() then
    raise exception 'دسترسی غیرمجاز';
  end if;
  if char_length(trim(coalesce(p_name, ''))) = 0 then
    raise exception 'نام محصول اجباری است';
  end if;
  update public.products
     set name = trim(p_name), archived = coalesce(p_archived, false)
   where id = p_id;
  if not found then raise exception 'محصول پیدا نشد'; end if;
end;
$$;

create or replace function public.set_base_price(p_id uuid, p_price bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_mahdi() then
    raise exception 'دسترسی غیرمجاز';
  end if;
  if coalesce(p_price, 0) < 0 then
    raise exception 'قیمت نمی‌تواند منفی باشد';
  end if;
  update public.products set base_price = p_price where id = p_id;
  if not found then raise exception 'محصول پیدا نشد'; end if;
end;
$$;

-- p_mode = 'percent': new = round(old * (1 + p_value/100))
-- p_mode = 'fixed'  : new = old + p_value          (p_value may be negative)
-- result is clamped to >= 0; returns the number of updated rows.
create or replace function public.bulk_price_update(
  p_ids   uuid[],
  p_mode  text,
  p_value numeric
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer := 0;
  v_new   bigint;
  v_row   record;
begin
  if not public.is_mahdi() then
    raise exception 'دسترسی غیرمجاز';
  end if;
  if p_mode not in ('percent', 'fixed') then
    raise exception 'نوع تغییر نامعتبر است';
  end if;
  if p_value is null then raise exception 'مقدار تغییر اجباری است'; end if;

  for v_row in
    select id, base_price from public.products where id = any(p_ids) order by id
  loop
    if p_mode = 'percent' then
      v_new := round(v_row.base_price * (1 + p_value / 100))::bigint;
    else
      v_new := round(v_row.base_price + p_value)::bigint;
    end if;
    if v_new < 0 then v_new := 0; end if;
    update public.products set base_price = v_new where id = v_row.id;
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- Both partners may edit their own number; nothing else on the card changes.
create or replace function public.set_hp(p_id uuid, p_hp bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_member() then
    raise exception 'دسترسی غیرمجاز';
  end if;
  if coalesce(p_hp, 0) < 0 then raise exception 'سود نمی‌تواند منفی باشد'; end if;
  update public.products set hp = p_hp where id = p_id;
  if not found then raise exception 'محصول پیدا نشد'; end if;
end;
$$;

create or replace function public.set_availability(p_id uuid, p_available boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_mahdi() then
    raise exception 'دسترسی غیرمجاز';
  end if;
  if p_available is null then raise exception 'وضعیت موجودی اجباری است'; end if;
  -- Existing orders keep their snapshot: availability only affects new orders.
  update public.products set available = p_available where id = p_id;
  if not found then raise exception 'محصول پیدا نشد'; end if;
end;
$$;

-- ==========================================================================
--  RPC: create_order — server-side calculation, atomic, no stock handling
-- ==========================================================================

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
  p_status           text     default null
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
  v_mahdi_disc   bigint;
  v_helia_disc   bigint;
  v_ship_fee     bigint;
  v_net          bigint;
  v_total        bigint;
  v_payout       bigint;
  v_goods_owe    bigint;
  v_owe          bigint;
  v_h_share      bigint;
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
  if p_method not in ('cash', 'snapp') then
    raise exception 'روش پرداخت نامعتبر است';
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

  if p_method = 'snapp' then
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

  -- ---------- discount split (same rules as calc.js) --------------------
  if p_discount_bearer = 'helia' then
    v_mahdi_disc := 0;             v_helia_disc := v_discount;
  elsif p_discount_bearer = 'mahdi' then
    v_mahdi_disc := v_discount;    v_helia_disc := 0;
  else
    v_mahdi_disc := v_discount / 2;            -- integer division = floor
    v_helia_disc := v_discount - v_mahdi_disc;
  end if;

  v_ship_fee := case when p_shipping_method = 'post' then v_post_fee else 0 end;
  v_net      := v_sub - v_discount;

  if p_method = 'snapp' then
    v_total := public.round_to_step(v_net * v_mult, v_step) + v_ship_fee;
  else
    v_total := v_net + v_ship_fee;
  end if;

  v_payout    := v_net + v_ship_fee;
  v_goods_owe := v_base_sum - v_mahdi_disc;
  if v_goods_owe < 0 then
    raise exception 'تخفیف بر عهده مغازه از مبلغ کالاهای مغازه بیشتر است';
  end if;
  v_owe     := v_goods_owe + v_ship_fee;
  v_h_share := v_hp_sum - v_helia_disc;

  -- invariant: every toman is either owed to the shop or kept by the page
  if (v_owe + v_h_share) <> v_payout then
    raise exception 'خطای محاسباتی: سهم‌ها با پرداختی برابر نیستند';
  end if;
  if v_h_share < 0 then
    raise notice 'هشدار: سود پیج منفی می‌شود؛ تخفیف را کم کنید';
  end if;

  v_hist := jsonb_build_array(jsonb_build_object(
    'status', v_status, 'at', now(), 'by', v_uid));

  -- ---------- insert the order (atomic: one statement, one transaction) --
  insert into public.orders (
    customer, phone, address, postal_code, items, method, shipping_method,
    shipping_fee, snapp_multiplier, rounding_step, discount, discount_bearer,
    mahdi_discount, helia_discount, total, owe, h_share, payout,
    status, status_history, note, last_actor
  ) values (
    trim(p_customer), trim(public.normalize_digits(p_phone)), trim(p_address), v_postal,
    v_out_items, p_method, p_shipping_method, v_ship_fee, v_mult, v_step,
    v_discount, p_discount_bearer, v_mahdi_disc, v_helia_disc,
    v_total, v_owe, v_h_share, v_payout, v_status, v_hist, coalesce(p_note, ''),
    v_uid
  ) returning id into v_order_id;

  return v_order_id;
end;
$$;

-- cancel_order: only marks the order cancelled (no stock restore, section 3.2)
create or replace function public.cancel_order(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  o record;
begin
  if not public.is_member() then raise exception 'دسترسی غیرمجاز'; end if;

  select * into o from public.orders where id = p_order_id for update;
  if not found then raise exception 'سفارش پیدا نشد'; end if;
  if o.status = 'cancelled' then return; end if;
  if o.status in ('shipped', 'delivered') then
    raise exception 'این سفارش ارسال شده و قابل لغو نیست؛ برای پیگیری سنجاق کنید';
  end if;

  update public.orders
     set status = 'cancelled',
         last_actor = auth.uid(),
         status_history = status_history || public.order_history_entry('cancelled', null)
   where id = p_order_id;
end;
$$;

-- --------------------------------------------------------------------------
-- RLS: products are readable by members only and never written directly
-- --------------------------------------------------------------------------
drop policy if exists products_select on public.products;
create policy products_select on public.products
  for select to authenticated
  using (public.is_member());
-- no INSERT/UPDATE/DELETE policy on purpose: writes go through the RPCs above

-- --------------------------------------------------------------------------
-- REVOKE / GRANT for the functions created by this migration
-- --------------------------------------------------------------------------
do $$
declare
  f record;
begin
  for f in
    select p.proname, pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('is_member','is_mahdi','my_role',
                         'add_product','update_product','set_hp',
                         'set_base_price','set_availability','bulk_price_update',
                         'create_order','set_order_status','cancel_order',
                         'bulk_set_status','set_tracking','set_pin',
                         'update_order_info')
  loop
    execute format('revoke all on function public.%I(%s) from PUBLIC', f.proname, f.args);
    execute format('revoke all on function public.%I(%s) from anon', f.proname, f.args);
    execute format('revoke all on function public.%I(%s) from authenticated', f.proname, f.args);
    execute format('grant execute on function public.%I(%s) to authenticated', f.proname, f.args);
    execute format('grant execute on function public.%I(%s) to service_role', f.proname, f.args);
  end loop;
end $$;
