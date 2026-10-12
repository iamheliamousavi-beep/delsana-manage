-- ==========================================================================
-- Delsana Management — Supabase schema, security and RPCs
-- Paste this whole file into the Supabase SQL Editor and run it once.
--
-- This file is a FRESH INSTALL and is kept equal to
-- "migrations/001_security.sql + migrations/002_simplify_products.sql
--  applied to a brand new database".
-- For an existing database follow README -> "Upgrading" instead.
--
-- Design notes:
--   * Every money value is an integer (toman). The only non-integer is the
--     Snapp multiplier (numeric), applied and then rounded.
--   * A product has only base_price (what the shop sells it for) and hp
--     (the page's profit per unit). There is no cost, no shop profit and no
--     stock: both partners see every number.
--   * orders.items stores a {product_id, name, qty, base, hp} snapshot, so
--     old orders stay readable after a price change.
--   * All writes that touch money/status go through SECURITY DEFINER RPCs
--     which re-compute everything server side from the products table.
--   * create_order / cancel_order are atomic (single function = one
--     transaction).
--   * RLS checks MEMBERSHIP (a row in public.profiles), not merely
--     `authenticated`: the anon key is public. Also turn OFF "Allow new
--     users to sign up" in the Supabase dashboard.
-- ==========================================================================

create extension if not exists pgcrypto;

-- --------------------------------------------------------------------------
-- helpers
-- --------------------------------------------------------------------------

-- Persian (۰-۹) and Arabic-Indic (٠-٩) digits -> ASCII digits
create or replace function public.normalize_digits(t text)
returns text
language sql
immutable
parallel safe
as $$
  select translate(coalesce(t, ''),
    '۰۱۲۳۴۵۶۷۸۹٠١٢٣٤٥٦٧٨٩',
    '01234567890123456789');
$$;

-- round half away from zero, to the given step (JS: Math.round(x/step)*step)
create or replace function public.round_to_step(x numeric, step bigint)
returns bigint
language sql
immutable
parallel safe
as $$
  select case
    when step is null or step <= 0 then round(x)::bigint
    else (round(x / step) * step)::bigint
  end;
$$;

-- --------------------------------------------------------------------------
-- profiles and role checks
-- --------------------------------------------------------------------------

create table if not exists public.profiles (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  role       text not null check (role in ('mahdi', 'helia', 'admin')),
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

create or replace function public.is_mahdi()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  -- the admin inherits every shop power (migration 007)
  select exists (
    select 1 from public.profiles where user_id = auth.uid() and role in ('mahdi', 'admin')
  );
$$;

-- Admin-only controls (the test-mode switch). The store never has this.
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles where user_id = auth.uid() and role = 'admin'
  );
$$;

create or replace function public.my_role()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select role from public.profiles where user_id = auth.uid();
$$;

-- Does the current user belong to this installation at all?
-- Every read policy and most RPCs are based on this one predicate.
create or replace function public.is_member()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.profiles where user_id = auth.uid());
$$;

-- No UPDATE/DELETE policy on purpose: the role can never be changed by a
-- client. Rows are inserted by the dashboard / SQL editor (owner bypasses RLS).
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles
  for select to authenticated
  using (user_id = auth.uid() or public.is_mahdi() or public.is_admin());

-- --------------------------------------------------------------------------
-- products (readable by both partners, written only through RPCs)
-- --------------------------------------------------------------------------

create table if not exists public.products (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (char_length(trim(name)) > 0),
  base_price bigint not null default 0 check (base_price >= 0),
  hp         bigint not null default 0 check (hp >= 0),
  available  boolean not null default true,
  archived   boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.products enable row level security;

drop policy if exists products_select on public.products;
create policy products_select on public.products
  for select to authenticated
  using (public.is_member());
-- no INSERT/UPDATE/DELETE policy on purpose: writes go through RPCs.

-- --------------------------------------------------------------------------
-- settings (both partners may edit; changes only affect NEW orders)
-- --------------------------------------------------------------------------

create table if not exists public.settings (
  key   text primary key,
  value text not null
);

alter table public.settings enable row level security;

insert into public.settings (key, value) values
  ('post_fee', '190000'),
  ('snapp_multiplier', '1.15'),
  ('rounding_step', '5000'),
  ('telegram_paused', '0')
on conflict (key) do nothing;

drop policy if exists settings_select on public.settings;
create policy settings_select on public.settings
  for select to authenticated
  using (public.is_member());

-- There is intentionally no INSERT policy: the client updates existing rows.
drop policy if exists settings_update on public.settings;
create policy settings_update on public.settings
  for update to authenticated
  using (public.is_member())
  with check (public.is_member() and (
    (key = 'snapp_multiplier' and value ~ '^[0-9]+(\.[0-9]+)?$') or
    (key in ('post_fee', 'rounding_step') and value ~ '^[0-9]+$') or
    -- the test-mode switch is admin-only (migration 007)
    (key = 'telegram_paused' and value in ('0', '1') and public.is_admin())));

-- --------------------------------------------------------------------------
-- orders (both partners read; writes only through RPCs)
-- --------------------------------------------------------------------------

create table if not exists public.orders (
  id               uuid primary key default gen_random_uuid(),
  created_at       timestamptz not null default now(),
  customer         text not null default '',
  phone            text not null default '',
  address          text not null default '',
  postal_code      text not null default '',
  -- [{product_id, name, qty, base, hp}]  price snapshot of the order
  items            jsonb not null default '[]'::jsonb,
  method           text not null check (method in ('cash', 'snapp', 'mixed')),
  shipping_method  text not null check (shipping_method in ('post', 'courier')),
  shipping_fee     bigint not null default 0,
  snapp_multiplier numeric not null default 1.15,
  rounding_step    bigint not null default 5000,
  discount         bigint not null default 0 check (discount >= 0),
  discount_bearer  text not null default 'helia'
                     check (discount_bearer in ('helia', 'mahdi', 'split')),
  mahdi_discount   bigint not null default 0,
  helia_discount   bigint not null default 0,
  total            bigint not null default 0,   -- what the customer pays
  owe              bigint not null default 0,   -- what the page transfers to the shop
  h_share          bigint not null default 0,   -- what the page keeps
  payout           bigint not null default 0,   -- what Snapp Pay will deposit
  snapp_part       bigint not null default 0,   -- mixed only: the Snapp side S (customer Snapp charge)
  snapp_charge     bigint not null default 0,   -- mixed: = S; snapp: total; cash: 0
  cash_charge      bigint not null default 0,   -- mixed/cash: customer cash (incl. Snapp fee); snapp: 0
  snapp_fee        bigint not null default 0,   -- mixed only: snappRound(S)-S (0 when clamped)
  snapp_deposit    bigint not null default 0,   -- mixed: S-fee; snapp: payout; cash: 0
  status           text not null default 'new'
                     check (status in ('new', 'awaiting_snapp', 'paid',
                                       'settled', 'shipped', 'delivered',
                                       'cancelled')),
  status_history   jsonb not null default '[]'::jsonb,
  tracking         text not null default '',
  note             text not null default '',
  pinned           boolean not null default false,
  pin_note         text not null default '',
  pinned_at        timestamptz,
  -- the partner who made the last change (used by the notification outbox)
  last_actor       uuid
);

alter table public.orders enable row level security;

-- 4-invariant check (migrations 008+009): parts sum to total, deposit+cash
-- is the payout, shares sum to payout; mixed rows pin charge/deposit/fee.
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
end $$;

drop policy if exists orders_select on public.orders;
create policy orders_select on public.orders
  for select to authenticated
  using (public.is_member());

-- indexes required by the specification
create index if not exists orders_created_at_idx on public.orders (created_at desc);
create index if not exists orders_status_idx      on public.orders (status);
create index if not exists orders_tracking_idx    on public.orders (tracking);
create index if not exists orders_pinned_idx      on public.orders (pinned) where pinned = true;
create index if not exists products_name_idx      on public.products (name);

-- ==========================================================================
--  RPC: products — shop-only functions check is_mahdi(), everything else
--       checks is_member()
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

  -- one outbox row per call, never one per product (9.1)
  insert into public.outbox (kind, order_id, actor, payload)
  values ('prices_changed', null, auth.uid(), jsonb_build_object('count', 1));
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

  -- one outbox row for the whole batch, never one per product (9.1)
  if v_count > 0 then
    insert into public.outbox (kind, order_id, actor, payload)
    values ('prices_changed', null, auth.uid(), jsonb_build_object('count', v_count));
  end if;

  return v_count;
end;
$$;

-- The page edits only her own number.
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
--  RPC: order_amounts + create_order  (server-side calculation, atomic)
--
--  order_amounts is the ONE server-side implementation of the money math
--  (pure: immutable, no auth, no table access). create_order resolves
--  settings/overrides and product prices, then calls it.
-- ==========================================================================

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

  -- ---------- validate enums -------------------------------------------
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
           v_ship_fee, p_method, p_snapp_part, v_mult, v_step) as a;

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

-- ==========================================================================
--  RPC: status flow / cancel / tracking / pinning
-- ==========================================================================

create or replace function public.order_history_entry(p_status text, p_note text)
returns jsonb
language plpgsql
as $$
begin
  return jsonb_build_object(
    'status', p_status,
    'at', now(),
    'by', auth.uid(),
    'note', coalesce(nullif(trim(p_note), ''), null)
  );
end;
$$;

create or replace function public.set_order_status(
  p_order_id uuid,
  p_status   text,
  p_tracking text default null,
  p_note     text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  o record;
  v_next text[];
begin
  if not public.is_member() then raise exception 'دسترسی غیرمجاز'; end if;
  if p_status not in ('new','awaiting_snapp','paid','settled','shipped','delivered','cancelled') then
    raise exception 'وضعیت نامعتبر است';
  end if;

  select * into o from public.orders where id = p_order_id for update;
  if not found then raise exception 'سفارش پیدا نشد'; end if;
  if o.status = p_status then raise exception 'سفارش همین وضعیت را دارد'; end if;

  if p_status = 'cancelled' then
    perform public.cancel_order(p_order_id);
    return;
  end if;

  v_next := case o.status
    when 'new'            then array['paid','cancelled']
    when 'awaiting_snapp' then array['paid','cancelled']
    when 'paid'           then array['settled','cancelled']
    when 'settled'        then array['shipped','cancelled']
    when 'shipped'        then array['delivered']
    else array[]::text[]
  end;

  if not (p_status = any(v_next)) then
    raise exception 'تغییر وضعیت از «%» به «%» مجاز نیست', o.status, p_status;
  end if;

  if p_status = 'shipped' then
    -- the code may be registered days later (section 6): no requirement here
    update public.orders
       set status = 'shipped',
           tracking = case
             when char_length(trim(coalesce(p_tracking, ''))) > 0 then left(trim(p_tracking), 60)
             else tracking end,
           last_actor = auth.uid(),
           status_history = status_history || public.order_history_entry('shipped', p_note)
     where id = p_order_id;
  else
    update public.orders
       set status = p_status,
           last_actor = auth.uid(),
           status_history = status_history || public.order_history_entry(p_status, p_note)
     where id = p_order_id;
  end if;
end;
$$;

-- cancel_order: only marks the order cancelled (no stock restore)
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

-- Bulk helper for the Accounts screen.
-- p_target = 'settled' (from paid) | 'paid' (from new or awaiting_snapp)
create or replace function public.bulk_set_status(p_order_ids uuid[], p_target text)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_from text[];
  v_count integer := 0;
  r record;
begin
  if not public.is_member() then raise exception 'دسترسی غیرمجاز'; end if;
  if p_target = 'settled' then v_from := array['paid'];
  elsif p_target = 'paid'  then v_from := array['new','awaiting_snapp'];
  else raise exception 'وضعیت مقصد نامعتبر است';
  end if;

  for r in
    select id from public.orders
     where id = any(p_order_ids) and status = any(v_from)
     order by created_at
     for update
  loop
    update public.orders
       set status = p_target,
           last_actor = auth.uid(),
           status_history = status_history || public.order_history_entry(p_target, null)
     where id = r.id;
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

create or replace function public.set_tracking(p_order_id uuid, p_tracking text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_member() then raise exception 'دسترسی غیرمجاز'; end if;

  if not exists (select 1 from public.orders where id = p_order_id) then
    raise exception 'سفارش پیدا نشد';
  end if;

  update public.orders
     set tracking = left(trim(coalesce(p_tracking, '')), 60),
         last_actor = auth.uid()
   where id = p_order_id
     and status <> 'cancelled';
  if not found then
    raise exception 'سفارش لغوشده است و قابل ویرایش نیست';
  end if;
end;
$$;

-- section 7.1 — edit customer data only; money is never editable
create or replace function public.update_order_info(
  p_order_id    uuid,
  p_customer    text,
  p_phone       text,
  p_address     text,
  p_postal_code text,
  p_note        text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  o record;
  v_postal text;
begin
  if not public.is_member() then raise exception 'دسترسی غیرمجاز'; end if;

  select * into o from public.orders where id = p_order_id for update;
  if not found then raise exception 'سفارش پیدا نشد'; end if;
  if o.status = 'cancelled' then
    raise exception 'سفارش لغوشده قابل ویرایش نیست';
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

  update public.orders
     set customer    = trim(p_customer),
         phone       = trim(public.normalize_digits(p_phone)),
         address     = trim(p_address),
         postal_code = v_postal,
         note        = coalesce(p_note, ''),
         last_actor  = auth.uid()
   where id = p_order_id;
end;
$$;

create or replace function public.set_pin(
  p_order_id uuid,
  p_pinned   boolean,
  p_pin_note text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_member() then raise exception 'دسترسی غیرمجاز'; end if;
  update public.orders
     set pinned = p_pinned,
         pin_note = case when p_pinned then left(coalesce(p_pin_note, ''), 300) else '' end,
         pinned_at = case when p_pinned then now() else null end,
         last_actor = auth.uid()
   where id = p_order_id;
  if not found then raise exception 'سفارش پیدا نشد'; end if;
end;
$$;


-- ===========================================================================
-- 004_bulk_set_tracking.sql
--
-- bulk_set_tracking: register many postal tracking codes in one call.
-- Used by the «ایمپورت لیست پست» dialog (post-office PDF import).
--
--   p_items        jsonb array of {"order_id": "<uuid>", "tracking": "<code>"},
--                  1..200 entries; no duplicate order_id and no duplicate
--                  tracking inside the payload
--   p_overwrite    replace an existing different code when true (default false)
--   p_mark_shipped also move status 'settled' -> 'shipped' (default false)
--
-- Returns {"updated": <int>, "skipped": [{"order_id": "...", "reason": "..."}]}
-- with reason one of: not_found | cancelled | code_in_use | has_code.
--
-- Validation problems raise; per-order problems skip that order only. The
-- function only UPDATEs public.orders (never DELETE, no schema changes), so
-- tg_order_events keeps writing one tracking_changed outbox row per changed
-- order and the notify Edge Function works unchanged. Idempotent
-- (create or replace) and safe to run twice.
-- ===========================================================================

create or replace function public.bulk_set_tracking(
  p_items        jsonb,
  p_overwrite    boolean default false,
  p_mark_shipped boolean default false
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_updated integer := 0;
  v_skipped jsonb   := '[]'::jsonb;
  v_ids     uuid[]  := '{}';
  v_codes   text[]  := '{}';
  v_map     jsonb;
  e         jsonb;
  v_order   uuid;
  v_code    text;
  o         record;
begin
  if not public.is_member() then raise exception 'دسترسی غیرمجاز'; end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'لیست اقلام نامعتبر است';
  end if;
  if jsonb_array_length(p_items) < 1 or jsonb_array_length(p_items) > 200 then
    raise exception 'تعداد اقلام باید بین ۱ تا ۲۰۰ باشد';
  end if;

  -- 1) validate the whole payload before touching any row
  for e in select value from jsonb_array_elements(p_items) loop
    if e->>'order_id' is null or e->>'order_id' !~*
         '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'شناسه سفارش نامعتبر است';
    end if;
    v_order := (e->>'order_id')::uuid;
    v_code  := left(trim(public.normalize_digits(coalesce(e->>'tracking', ''))), 60);
    if char_length(v_code) < 1 then
      raise exception 'کد رهگیری خالی است';
    end if;
    if v_order = any(v_ids) then
      raise exception 'سفارش «%» دو بار در لیست آمده است', v_order;
    end if;
    if v_code = any(v_codes) then
      raise exception 'کد «%» دو بار در لیست آمده است', v_code;
    end if;
    v_ids   := v_ids   || v_order;
    v_codes := v_codes || v_code;
  end loop;

  select coalesce(jsonb_object_agg(id, code), '{}'::jsonb)
    into v_map
    from (select u as id, c as code from unnest(v_ids, v_codes) as t(id, code)) s;

  -- 2) lock the orders in ascending id order (no deadlocks between
  --    concurrent imports) and apply the rules one by one
  for v_order in select u from unnest(v_ids) u order by 1 loop
    v_code := v_map->>v_order::text;

    select * into o from public.orders where id = v_order for update;
    if not found then
      v_skipped := v_skipped || jsonb_build_array(
        jsonb_build_object('order_id', v_order, 'reason', 'not_found'));
      continue;
    end if;
    if o.status = 'cancelled' then
      v_skipped := v_skipped || jsonb_build_array(
        jsonb_build_object('order_id', v_order, 'reason', 'cancelled'));
      continue;
    end if;
    if exists (select 1 from public.orders where tracking = v_code and id <> v_order) then
      v_skipped := v_skipped || jsonb_build_array(
        jsonb_build_object('order_id', v_order, 'reason', 'code_in_use'));
      continue;
    end if;
    if coalesce(o.tracking, '') <> '' and o.tracking <> v_code
       and not coalesce(p_overwrite, false) then
      v_skipped := v_skipped || jsonb_build_array(
        jsonb_build_object('order_id', v_order, 'reason', 'has_code'));
      continue;
    end if;

    if coalesce(p_mark_shipped, false) and o.status = 'settled' then
      update public.orders
         set tracking       = v_code,
             status         = 'shipped',
             last_actor     = auth.uid(),
             status_history = status_history || public.order_history_entry('shipped', null)
       where id = v_order;
    else
      update public.orders
         set tracking   = v_code,
             last_actor = auth.uid()
       where id = v_order;
    end if;
    v_updated := v_updated + 1;
  end loop;

  return jsonb_build_object('updated', v_updated, 'skipped', v_skipped);
end;
$$;

revoke all on function public.bulk_set_tracking(jsonb, boolean, boolean) from PUBLIC, anon, authenticated;
grant execute on function public.bulk_set_tracking(jsonb, boolean, boolean) to authenticated, service_role;

-- make PostgREST pick the new function up immediately (harmless if repeated);
-- without this a stale schema cache keeps answering 400/404 for a few seconds
notify pgrst, 'reload schema';
-- ==========================================================================
--  Realtime
-- ==========================================================================

do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  alter publication supabase_realtime add table public.orders;
exception when duplicate_object then null; end $$;

do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  alter publication supabase_realtime add table public.products;
exception when duplicate_object then null; end $$;

do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  alter publication supabase_realtime add table public.settings;
exception when duplicate_object then null; end $$;

-- ==========================================================================
--  Grants: authenticated only (never anon) for every RPC
-- ==========================================================================

do $$
declare
  f record;
begin
  for f in
    select p.proname, pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('is_member','is_mahdi','is_admin','my_role',
                         'order_amounts',
                         'add_product','update_product','set_hp',
                         'set_base_price','set_availability','bulk_price_update',
                         'create_order','set_order_status','cancel_order',
                         'bulk_set_status','set_tracking','set_pin',
                         'update_order_info','bulk_set_tracking')
  loop
    execute format('revoke all on function public.%I(%s) from PUBLIC', f.proname, f.args);
    execute format('revoke all on function public.%I(%s) from anon', f.proname, f.args);
    execute format('revoke all on function public.%I(%s) from authenticated', f.proname, f.args);
    execute format('grant execute on function public.%I(%s) to authenticated', f.proname, f.args);
    execute format('grant execute on function public.%I(%s) to service_role', f.proname, f.args);
  end loop;
end $$;

-- Table privileges: only authenticated users. Row Level Security decides
-- which rows (and the RPCs above decide which columns) each role touches.
-- A failure is reported, never swallowed silently (section 5.15).
do $$
begin
  execute 'revoke all on all tables in schema public from anon';
  execute 'grant usage on schema public to anon, authenticated';
  execute 'grant select on all tables in schema public to authenticated';
  execute 'grant update on public.settings to authenticated';
  execute 'grant all on all tables in schema public to service_role';
exception when others then
  raise warning 'privilege block failed: %', sqlerrm;
end $$;

-- ==========================================================================
--  Creating the users (admin + page now, store later)
-- ==========================================================================
-- 1) Supabase Dashboard -> Authentication -> Users -> "Add user"
--    (email + password, "Auto confirm user" = ON). Create two users: the
--    admin (the human behind the former store login — same email/password)
--    and the page. The store slot stays EMPTY for now (no credentials).
-- 2) Then insert their profile rows (replace the UUIDs):
--
-- insert into public.profiles (user_id, role) values
--   ('<uuid of admin>', 'admin'),
--   ('<uuid of helia>', 'helia')
-- on conflict (user_id) do update set role = excluded.role;
--
-- Existing database? Run migrations/007_admin_role.sql first, then promote:
--   update public.profiles set role = 'admin'
--    where user_id = (select id from auth.users where email = '<store email>');
-- Later, when the store needs its own login: create its Dashboard user, then:
--   insert into public.profiles (user_id, role)
--   values ('<new store user uuid>', 'mahdi');
--
-- 3) IMPORTANT: Supabase Dashboard -> Authentication -> Sign In / Providers
--    -> turn OFF "Allow new users to sign up".  The anon key is public and
--    public sign-up would otherwise expose every order.
--
-- Never give the frontend the service_role key.

-- ===========================================================================
-- 9.1  Notifications: schema, outbox, triggers, cron
--      (part B of migration 003 — mirrored byte-for-byte in setup.sql)
-- ===========================================================================

-- The extensions are built into Supabase. Where they are missing (a bare
-- PostgreSQL, e.g. the test harness) the failure is reported as a warning
-- instead of aborting the whole migration — section 5.15 style: reported,
-- never swallowed silently.
do $$
begin
  execute 'create extension if not exists pg_net';
exception when others then
  raise warning 'pg_net is not available: %', sqlerrm;
end $$;

do $$
begin
  execute 'create extension if not exists pg_cron';
exception when others then
  raise warning 'pg_cron is not available: %', sqlerrm;
end $$;

alter table public.orders
  add column if not exists last_actor uuid,
  add column if not exists tg_channel_msg_id bigint,
  add column if not exists tg_channel_hash text,
  add column if not exists tracking_reminded_at timestamptz;

create schema if not exists app_private;
create table if not exists app_private.config (key text primary key, value text not null);
revoke all on schema app_private from anon, authenticated;
revoke all on all tables in schema app_private from anon, authenticated;
grant usage on schema app_private to service_role;

create table if not exists public.outbox (
  id bigserial primary key,
  created_at timestamptz not null default now(),
  kind text not null,
  order_id uuid,
  actor uuid,
  payload jsonb not null default '{}'::jsonb,
  processed_at timestamptz,
  attempts int not null default 0,
  last_error text);
create index if not exists outbox_pending_idx on public.outbox (id) where processed_at is null;
alter table public.outbox enable row level security;

create table if not exists public.telegram_links (
  token text primary key,
  user_id uuid not null references auth.users on delete cascade,
  expires_at timestamptz not null,
  used boolean not null default false);
alter table public.telegram_links enable row level security;

create table if not exists public.telegram_chats (
  user_id uuid primary key references auth.users on delete cascade,
  chat_id bigint not null unique,
  connected_at timestamptz not null default now(),
  active boolean not null default true);
alter table public.telegram_chats enable row level security;

create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  user_agent text,
  created_at timestamptz not null default now(),
  last_ok_at timestamptz);
alter table public.push_subscriptions enable row level security;

-- ---------------------------------------------------------------------------
-- RPCs: linking Telegram and managing push subscriptions (member only)
-- ---------------------------------------------------------------------------
create or replace function public.create_telegram_link()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_token text;
begin
  if not public.is_member() then raise exception 'دسترسی غیرمجاز'; end if;

  delete from public.telegram_links where user_id = auth.uid() and used = false;
  v_token := md5(gen_random_uuid()::text || clock_timestamp()::text || auth.uid()::text);
  insert into public.telegram_links (token, user_id, expires_at)
  values (v_token, auth.uid(), now() + interval '15 minutes');
  return v_token;
end;
$$;

create or replace function public.my_notification_status()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_member() then raise exception 'دسترسی غیرمجاز'; end if;
  return jsonb_build_object(
    'telegram_connected', exists(
      select 1 from public.telegram_chats where user_id = auth.uid() and active),
    'push_devices', (
      select count(*) from public.push_subscriptions where user_id = auth.uid()));
end;
$$;

create or replace function public.disconnect_telegram()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_member() then raise exception 'دسترسی غیرمجاز'; end if;
  delete from public.telegram_chats where user_id = auth.uid();
end;
$$;

create or replace function public.save_push_subscription(
  p_endpoint  text,
  p_p256dh    text,
  p_auth      text,
  p_user_agent text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_member() then raise exception 'دسترسی غیرمجاز'; end if;
  if char_length(trim(coalesce(p_endpoint, ''))) = 0 then
    raise exception 'آدرس اعلان اجباری است';
  end if;
  if coalesce(p_p256dh, '') = '' or coalesce(p_auth, '') = '' then
    raise exception 'کلید اعلان نامعتبر است';
  end if;

  insert into public.push_subscriptions (user_id, endpoint, p256dh, auth, user_agent, last_ok_at)
  values (auth.uid(), trim(p_endpoint), p_p256dh, p_auth, p_user_agent, now())
  on conflict (endpoint) do update
    set user_id     = excluded.user_id,
        p256dh      = excluded.p256dh,
        auth        = excluded.auth,
        user_agent  = excluded.user_agent,
        last_ok_at  = now();
end;
$$;

create or replace function public.remove_push_subscription(p_endpoint text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_member() then raise exception 'دسترسی غیرمجاز'; end if;
  delete from public.push_subscriptions
   where user_id = auth.uid() and endpoint = trim(coalesce(p_endpoint, ''));
end;
$$;

-- ---------------------------------------------------------------------------
-- wake the Edge Function (trigger + pg_cron both use this); a failure is
-- reported and never rolls back the order that caused it
-- ---------------------------------------------------------------------------
create or replace function public.wake_notifier()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url    text;
  v_secret text;
begin
  select value into v_url    from app_private.config where key = 'notify_url';
  select value into v_secret from app_private.config where key = 'webhook_secret';
  if v_url is null or v_url = '' then
    raise notice 'notify_url is not configured; the wake-up call is skipped';
    return;
  end if;

  perform net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-webhook-secret', coalesce(v_secret, '')),
    body := '{}'::jsonb);
exception when others then
  raise warning 'notify wake-up failed: %', sqlerrm;
end;
$$;

create or replace function public.tg_outbox_wake()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.wake_notifier();
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- outbox writers
-- ---------------------------------------------------------------------------
create or replace function public.tg_order_events()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.outbox (kind, order_id, actor, payload)
    values ('order_created', NEW.id, NEW.last_actor, '{}'::jsonb);
    return NEW;
  end if;

  if OLD.status is distinct from NEW.status then
    insert into public.outbox (kind, order_id, actor, payload)
    values ('status_changed', NEW.id, NEW.last_actor,
            jsonb_build_object('from', OLD.status, 'to', NEW.status));
  end if;

  if coalesce(OLD.tracking, '') is distinct from coalesce(NEW.tracking, '') then
    insert into public.outbox (kind, order_id, actor, payload)
    values ('tracking_changed', NEW.id, NEW.last_actor,
            jsonb_build_object('from', coalesce(OLD.tracking, ''),
                               'to',   coalesce(NEW.tracking, '')));
  end if;

  if OLD.pinned is distinct from NEW.pinned
     or (NEW.pinned and OLD.pin_note is distinct from NEW.pin_note) then
    insert into public.outbox (kind, order_id, actor, payload)
    values ('pin_changed', NEW.id, NEW.last_actor,
            jsonb_build_object('pinned', NEW.pinned, 'note', coalesce(NEW.pin_note, '')));
  end if;

  return NEW;
end;
$$;

create or replace function public.tg_product_events()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if OLD.available is distinct from NEW.available then
    insert into public.outbox (kind, order_id, actor, payload)
    values ('availability_changed', null, auth.uid(),
            jsonb_build_object('name', NEW.name, 'available', NEW.available,
                               'product_id', NEW.id));
  end if;
  return NEW;
end;
$$;

-- ---------------------------------------------------------------------------
-- daily reminder: shipped post orders that still have no code (section 9.1)
-- ---------------------------------------------------------------------------
create or replace function public.queue_tracking_missing()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ids uuid[];
begin
  select coalesce(array_agg(o.id), '{}') into v_ids
    from public.orders o
   where o.status = 'shipped'
     and o.shipping_method = 'post'
     and coalesce(o.tracking, '') = ''
     and coalesce((
           select max((h ->> 'at')::timestamptz)
             from jsonb_array_elements(o.status_history) h
            where h ->> 'status' = 'shipped'), o.created_at) < now() - interval '3 days'
     and (o.tracking_reminded_at is null or o.tracking_reminded_at < now() - interval '2 days');

  if array_length(v_ids, 1) is null then
    return 0;
  end if;

  insert into public.outbox (kind, order_id, actor, payload)
  values ('tracking_missing', null, null,
          jsonb_build_object('order_ids', to_jsonb(v_ids)));

  update public.orders set tracking_reminded_at = now() where id = any(v_ids);
  return array_length(v_ids, 1);
end;
$$;

-- ---------------------------------------------------------------------------
-- the Edge Function claims its batch in one atomic statement: attempts is
-- incremented and the rows come back together, so overlapping invocations
-- never send the same event twice (9.2, step 1)
-- ---------------------------------------------------------------------------
create or replace function public.claim_outbox(p_limit integer default 50)
returns setof public.outbox
language plpgsql
security definer
set search_path = public
as $$
declare
  v_limit integer;
begin
  v_limit := least(greatest(coalesce(p_limit, 50), 1), 50);
  return query
  with pending as (
    select id
      from public.outbox
     where processed_at is null
       and attempts < 5
     order by id
     limit v_limit
       for update skip locked
  ), claimed as (
    update public.outbox o
       set attempts = o.attempts + 1
      from pending
     where o.id = pending.id
    returning o.*
  )
  select * from claimed;
end;
$$;
-- ---------------------------------------------------------------------------
-- triggers
-- ---------------------------------------------------------------------------
drop trigger if exists orders_outbox on public.orders;
create trigger orders_outbox
  after insert or update on public.orders
  for each row execute function public.tg_order_events();

drop trigger if exists products_outbox on public.products;
create trigger products_outbox
  after update on public.products
  for each row execute function public.tg_product_events();

drop trigger if exists outbox_wake on public.outbox;
create trigger outbox_wake
  after insert on public.outbox
  for each row execute function public.tg_outbox_wake();

-- ---------------------------------------------------------------------------
-- pg_cron: wake every 2 minutes + the 06:30 UTC tracking reminder
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from cron.job where jobname = 'delsana-notify') then
    perform cron.unschedule('delsana-notify');
  end if;
  perform cron.schedule('delsana-notify', '*/2 * * * *',
                        'select public.wake_notifier();');
exception when others then
  raise warning 'pg_cron (delsana-notify) not scheduled: %', sqlerrm;
end $$;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'delsana-tracking-reminder') then
    perform cron.unschedule('delsana-tracking-reminder');
  end if;
  perform cron.schedule('delsana-tracking-reminder', '30 6 * * *',
                        'select public.queue_tracking_missing();');
exception when others then
  raise warning 'pg_cron (delsana-tracking-reminder) not scheduled: %', sqlerrm;
end $$;

-- ---------------------------------------------------------------------------
-- the event writers and the cron helpers are for the owner / service role
-- only: no client may execute them
-- ---------------------------------------------------------------------------
do $$
declare
  f record;
begin
  for f in
    select p.proname, pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('wake_notifier', 'tg_outbox_wake', 'tg_order_events',
                         'tg_product_events', 'queue_tracking_missing',
                         'claim_outbox')
  loop
    execute format('revoke all on function public.%I(%s) from PUBLIC, anon, authenticated',
                   f.proname, f.args);
  end loop;
end $$;

-- the claim function belongs to the service role (the Edge Function) only
grant execute on function public.claim_outbox(integer) to service_role;

-- ---------------------------------------------------------------------------
-- the notification RPCs: member only (never anon, never PUBLIC)
-- ---------------------------------------------------------------------------
do $$
declare
  f record;
begin
  for f in
    select p.proname, pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('create_telegram_link', 'my_notification_status',
                         'disconnect_telegram', 'save_push_subscription',
                         'remove_push_subscription')
  loop
    execute format('revoke all on function public.%I(%s) from PUBLIC', f.proname, f.args);
    execute format('revoke all on function public.%I(%s) from anon', f.proname, f.args);
    execute format('revoke all on function public.%I(%s) from authenticated', f.proname, f.args);
    execute format('grant execute on function public.%I(%s) to authenticated', f.proname, f.args);
    execute format('grant execute on function public.%I(%s) to service_role', f.proname, f.args);
  end loop;
end $$;

-- the notification tables are read by the Edge Function only (section 11)
do $$
begin
  execute 'grant all on public.outbox, public.telegram_links, public.telegram_chats, public.push_subscriptions to service_role';
  execute 'revoke all on public.outbox, public.telegram_links, public.telegram_chats, public.push_subscriptions from anon, authenticated';
exception when others then
  raise warning 'notification table grants failed: %', sqlerrm;
end $$;

-- ===========================================================================
-- 010_admin_edit_delete.sql (mirrored — see migrations/010_admin_edit_delete.sql)
-- ===========================================================================

-- ===========================================================================
-- 010_admin_edit_delete.sql
--
-- Admin can edit or delete any order and any product, with an audit trail.
-- ONLY the `admin` role (public.is_admin()); enforced in RLS + RPCs.
--
-- BEFORE running: export all orders as CSV from the app.
-- Every statement below is idempotent and safe to run twice.
-- Mirrored into setup.sql (fresh installs already contain the end state).
--
--   1. `audit_log` table (select: admin only via RPC; writes: RPCs only).
--   2. `admin_update_order` / `admin_delete_order` (any status, full money
--      recompute through public.order_amounts).
--   3. `admin_update_product` / `admin_delete_product` (snapshots in old
--      orders are untouched).
--   4. `admin_restore_order` / `admin_restore_product` (re-insert from the
--      delete audit entry with the ORIGINAL id).
--   5. `admin_list_audit` (latest N rows for the Settings audit card).
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1) audit log
-- ---------------------------------------------------------------------------
create table if not exists public.audit_log (
  id bigserial primary key,
  at timestamptz not null default now(),
  actor uuid not null,
  entity text not null check (entity in ('order', 'product')),
  entity_id uuid not null,
  action text not null check (action in ('edit', 'delete', 'restore')),
  before jsonb,
  after jsonb
);
create index if not exists audit_log_entity_idx
  on public.audit_log (entity, entity_id, at desc);

alter table public.audit_log enable row level security;
-- no policies on purpose: reads go through admin_list_audit, writes through
-- the admin RPCs below (all security definer). RLS with no policy = deny.

-- ---------------------------------------------------------------------------
-- 2) edit any order
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
  v_ship text; v_method text; v_snapp_part bigint; v_discount bigint;
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
    'shipping_method','method','snapp_part','discount','discount_bearer',
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
           v_ship_fee, v_method, v_snapp_part, v_mult, v_step) as a;

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
  for v_key in select jsonb_object_keys(p_data) loop
    v_changed := v_changed || v_key;
  end loop;
  if (v_after->>'total')::bigint is distinct from o.total then v_changed := v_changed || 'total'; end if;
  if (v_after->>'payout')::bigint is distinct from o.payout then v_changed := v_changed || 'payout'; end if;
  if (v_after->>'owe')::bigint is distinct from o.owe then v_changed := v_changed || 'owe'; end if;
  if (v_after->>'h_share')::bigint is distinct from o.h_share then v_changed := v_changed || 'h_share'; end if;

  insert into public.audit_log (actor, entity, entity_id, action, before, after)
  values (auth.uid(), 'order', p_order_id, 'edit', to_jsonb(o), v_after);

  insert into public.outbox (kind, order_id, actor, payload)
  values ('order_edited', p_order_id, auth.uid(),
          jsonb_build_object('changed', to_jsonb(v_changed)));

  return p_order_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3) delete any order (hard delete + audit + outbox, one transaction)
-- ---------------------------------------------------------------------------
create or replace function public.admin_delete_order(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  o record;
begin
  if not public.is_admin() then
    raise exception 'دسترسی غیرمجاز';
  end if;

  select * into o from public.orders where id = p_order_id for update;
  if not found then raise exception 'سفارش پیدا نشد'; end if;

  insert into public.audit_log (actor, entity, entity_id, action, before, after)
  values (auth.uid(), 'order', p_order_id, 'delete', to_jsonb(o), null);

  insert into public.outbox (kind, order_id, actor, payload)
  values ('order_deleted', p_order_id, auth.uid(),
          jsonb_build_object('customer', o.customer,
                             'tg_channel_msg_id', o.tg_channel_msg_id,
                             'total', o.total,
                             'status', o.status));

  -- the order is gone: never retry its other pending rows
  update public.outbox set processed_at = now()
   where order_id = p_order_id and processed_at is null and kind <> 'order_deleted';

  delete from public.orders where id = p_order_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4) edit / delete any product
-- ---------------------------------------------------------------------------
create or replace function public.admin_update_product(p_id uuid, p_data jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  o record;
  v_name text; v_base bigint; v_hp bigint; v_av boolean; v_ar boolean;
  v_key text;
  v_allowed text[] := array['name','base_price','hp','available','archived'];
  v_base_changed boolean := false;
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

  select * into o from public.products where id = p_id for update;
  if not found then raise exception 'محصول پیدا نشد'; end if;

  v_name := case when p_data ? 'name' then trim(p_data->>'name') else o.name end;
  v_base := case when p_data ? 'base_price' then (p_data->>'base_price')::bigint else o.base_price end;
  v_hp   := case when p_data ? 'hp' then (p_data->>'hp')::bigint else o.hp end;
  v_av   := case when p_data ? 'available' then (p_data->>'available')::boolean else o.available end;
  v_ar   := case when p_data ? 'archived' then (p_data->>'archived')::boolean else o.archived end;

  if char_length(trim(coalesce(v_name, ''))) = 0 then
    raise exception 'نام محصول اجباری است';
  end if;
  if v_base is null or v_base < 0 or v_hp is null or v_hp < 0 then
    raise exception 'قیمت نمی‌تواند منفی باشد';
  end if;
  if v_av is null then raise exception 'وضعیت موجودی اجباری است'; end if;
  v_base_changed := v_base is distinct from o.base_price;

  update public.products
     set name = v_name, base_price = v_base, hp = v_hp,
         available = v_av, archived = coalesce(v_ar, false)
   where id = p_id;

  insert into public.audit_log (actor, entity, entity_id, action, before, after)
  values (auth.uid(), 'product', p_id, 'edit', to_jsonb(o),
          (select to_jsonb(p) from public.products p where p.id = p_id));

  -- price changes notify like set_base_price does (availability changes fire
  -- the existing availability_changed trigger automatically)
  if v_base_changed then
    insert into public.outbox (kind, order_id, actor, payload)
    values ('prices_changed', null, auth.uid(), jsonb_build_object('count', 1));
  end if;
end;
$$;

create or replace function public.admin_delete_product(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  o record;
  v_n integer := 0;
begin
  if not public.is_admin() then
    raise exception 'دسترسی غیرمجاز';
  end if;

  select * into o from public.products where id = p_id for update;
  if not found then raise exception 'محصول پیدا نشد'; end if;

  -- orders keep their snapshots; count how many reference this product
  select count(*) into v_n from public.orders
   where exists (select 1 from jsonb_array_elements(items) e
                  where e->>'product_id' = p_id::text);

  insert into public.audit_log (actor, entity, entity_id, action, before, after)
  values (auth.uid(), 'product', p_id, 'delete', to_jsonb(o), null);

  delete from public.products where id = p_id;

  insert into public.outbox (kind, order_id, actor, payload)
  values ('product_deleted', null, auth.uid(), jsonb_build_object('name', o.name));

  return jsonb_build_object('deleted', true, 'referenced_by_orders', v_n);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5) restore a deleted order / product from its audit entry (original id)
-- ---------------------------------------------------------------------------
create or replace function public.admin_restore_order(p_audit_id bigint)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  a record;
  v_before jsonb;
  v_id uuid;
  v_new jsonb;
begin
  if not public.is_admin() then
    raise exception 'دسترسی غیرمجاز';
  end if;

  select * into a from public.audit_log where id = p_audit_id;
  if not found or a.entity <> 'order' or a.action <> 'delete' or a.before is null then
    raise exception 'مورد حذف‌شده پیدا نشد';
  end if;
  v_before := a.before;
  v_id := (v_before->>'id')::uuid;
  if exists (select 1 from public.orders where id = v_id) then
    raise exception 'این مورد قبلاً بازگردانده شده یا وجود دارد';
  end if;

  -- fresh channel message on restore: the INSERT trigger emits order_created
  v_before := v_before || jsonb_build_object('tg_channel_msg_id', null, 'last_actor', auth.uid());
  insert into public.orders
  select * from jsonb_populate_record(null::public.orders, v_before);
  select to_jsonb(x) into v_new from public.orders x where x.id = v_id;

  insert into public.audit_log (actor, entity, entity_id, action, before, after)
  values (auth.uid(), 'order', v_id, 'restore', null, v_new);

  return v_id;
end;
$$;

create or replace function public.admin_restore_product(p_audit_id bigint)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  a record;
  v_before jsonb;
  v_id uuid;
  v_new jsonb;
begin
  if not public.is_admin() then
    raise exception 'دسترسی غیرمجاز';
  end if;

  select * into a from public.audit_log where id = p_audit_id;
  if not found or a.entity <> 'product' or a.action <> 'delete' or a.before is null then
    raise exception 'مورد حذف‌شده پیدا نشد';
  end if;
  v_before := a.before;
  v_id := (v_before->>'id')::uuid;
  if exists (select 1 from public.products where id = v_id) then
    raise exception 'این مورد قبلاً بازگردانده شده یا وجود دارد';
  end if;

  insert into public.products
  select * from jsonb_populate_record(null::public.products, v_before);
  select to_jsonb(x) into v_new from public.products x where x.id = v_id;

  insert into public.audit_log (actor, entity, entity_id, action, before, after)
  values (auth.uid(), 'product', v_id, 'restore', null, v_new);

  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6) audit listing for the admin UI (the table has no client policies)
-- ---------------------------------------------------------------------------
create or replace function public.admin_list_audit(p_limit integer default 100)
returns setof public.audit_log
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'دسترسی غیرمجاز';
  end if;
  return query
  select * from public.audit_log
   order by at desc
   limit least(greatest(coalesce(p_limit, 100), 1), 100);
end;
$$;

-- ---------------------------------------------------------------------------
-- grants (authenticated only, never anon)
-- ---------------------------------------------------------------------------
do $$
declare
  f record;
begin
  for f in
    select p.proname, pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('admin_update_order','admin_delete_order',
                         'admin_update_product','admin_delete_product',
                         'admin_restore_order','admin_restore_product',
                         'admin_list_audit')
  loop
    execute format('revoke all on function public.%I(%s) from PUBLIC', f.proname, f.args);
    execute format('revoke all on function public.%I(%s) from anon', f.proname, f.args);
    execute format('revoke all on function public.%I(%s) from authenticated', f.proname, f.args);
    execute format('grant execute on function public.%I(%s) to authenticated', f.proname, f.args);
    execute format('grant execute on function public.%I(%s) to service_role', f.proname, f.args);
  end loop;
end $$;

-- audit_log stays without any client privilege: RLS is enabled with no
-- policy (deny), and the security-definer RPCs run as the table owner.
-- (Fresh installs inherit this from the earlier privilege block running
-- before this section; existing databases change nothing here.)

notify pgrst, 'reload schema';
