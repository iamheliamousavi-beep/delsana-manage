-- ==========================================================================
-- Delsana Management — Supabase schema, security and RPCs
-- Paste this whole file into the Supabase SQL Editor and run it once.
--
-- Design notes:
--   * Every money value is an integer (toman). The only non-integer is the
--     Snapp multiplier (numeric), applied and then rounded.
--   * Helia must never read Mahdi's purchase cost / profit, therefore:
--       - product_costs and order_private are Mahdi-only (RLS);
--       - orders.items only stores {product_id, name, qty, base, hp};
--       - the per-line cost/mp snapshot lives in order_private.items;
--       - all writes that touch money/status go through SECURITY DEFINER
--         RPCs which re-compute everything server side from product_costs.
--   * create_order / cancel_order are atomic (single function = one
--     transaction): stock is decremented/restored together with the order.
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
  role       text not null check (role in ('mahdi', 'helia')),
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
  select exists (
    select 1 from public.profiles where user_id = auth.uid() and role = 'mahdi'
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

-- No UPDATE/DELETE policy on purpose: the role can never be changed by a
-- client. Rows are inserted by the dashboard / SQL editor (owner bypasses RLS).
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles
  for select to authenticated
  using (user_id = auth.uid() or public.is_mahdi());

-- --------------------------------------------------------------------------
-- products (readable by both partners)
-- --------------------------------------------------------------------------

create table if not exists public.products (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (char_length(trim(name)) > 0),
  stock      integer not null default 0 check (stock >= 0),
  hp         bigint not null default 0 check (hp >= 0),
  base_price bigint not null default 0 check (base_price >= 0),
  archived   boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.products enable row level security;

-- Mahdi's cost + profit per product. Helia must never read or write it.
create table if not exists public.product_costs (
  product_id uuid primary key references public.products(id) on delete cascade,
  cost       bigint not null default 0 check (cost >= 0),
  mp         bigint not null default 0 check (mp >= 0)
);

alter table public.product_costs enable row level security;

-- keep products.base_price in sync with cost + mp
create or replace function public.sync_base_price()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.products
     set base_price = new.cost + new.mp
   where id = new.product_id;
  return new;
end;
$$;

drop trigger if exists trg_sync_base_price on public.product_costs;
create trigger trg_sync_base_price
  after insert or update on public.product_costs
  for each row execute function public.sync_base_price();

drop policy if exists products_select on public.products;
create policy products_select on public.products
  for select to authenticated using (true);

drop policy if exists product_costs_select on public.product_costs;
create policy product_costs_select on public.product_costs
  for select to authenticated using (public.is_mahdi());

drop policy if exists product_costs_insert on public.product_costs;
create policy product_costs_insert on public.product_costs
  for insert to authenticated with check (public.is_mahdi());

drop policy if exists product_costs_update on public.product_costs;
create policy product_costs_update on public.product_costs
  for update to authenticated
  using (public.is_mahdi()) with check (public.is_mahdi());

-- no INSERT/UPDATE policies on products: they go through SECURITY DEFINER RPCs.

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
  ('rounding_step', '5000')
on conflict (key) do nothing;

drop policy if exists settings_select on public.settings;
create policy settings_select on public.settings
  for select to authenticated using (true);

drop policy if exists settings_update on public.settings;
create policy settings_update on public.settings
  for update to authenticated using (true) with check (true);

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
  -- [{product_id, name, qty, base, hp}]  (Helia-safe snapshot)
  items            jsonb not null default '[]'::jsonb,
  method           text not null check (method in ('cash', 'snapp')),
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
  owe              bigint not null default 0,   -- Helia owes Mahdi
  h_share          bigint not null default 0,   -- Helia's profit
  payout           bigint not null default 0,   -- what Snapp Pay will deposit
  status           text not null default 'new'
                     check (status in ('new', 'awaiting_snapp', 'paid',
                                       'settled', 'shipped', 'delivered',
                                       'cancelled')),
  status_history   jsonb not null default '[]'::jsonb,
  tracking         text not null default '',
  note             text not null default '',
  pinned           boolean not null default false,
  pin_note         text not null default '',
  pinned_at        timestamptz
);

alter table public.orders enable row level security;

-- Mahdi-only private data: cost snapshot + his profit per order
create table if not exists public.order_private (
  order_id   uuid primary key references public.orders(id) on delete cascade,
  cost_total bigint not null default 0,  -- sum(q * cost)
  m_profit   bigint not null default 0,  -- sum(q * mp) - mahdi_discount
  -- [{product_id, qty, cost, mp}] full price snapshot, Mahdi only
  items      jsonb not null default '[]'::jsonb
);

alter table public.order_private enable row level security;

drop policy if exists orders_select on public.orders;
create policy orders_select on public.orders
  for select to authenticated using (true);

drop policy if exists order_private_select on public.order_private;
create policy order_private_select on public.order_private
  for select to authenticated using (public.is_mahdi());

-- indexes required by the specification
create index if not exists orders_created_at_idx on public.orders (created_at desc);
create index if not exists orders_status_idx      on public.orders (status);
create index if not exists orders_tracking_idx    on public.orders (tracking);
create index if not exists orders_pinned_idx      on public.orders (pinned) where pinned = true;
create index if not exists products_name_idx      on public.products (name);

-- ==========================================================================
--  RPC: products
-- ==========================================================================

create or replace function public.add_product(
  p_name  text,
  p_stock integer,
  p_cost  bigint,
  p_mp    bigint,
  p_hp    bigint
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if auth.uid() is null or not public.is_mahdi() then
    raise exception 'دسترسی غیرمجاز';
  end if;
  if char_length(trim(coalesce(p_name, ''))) = 0 then
    raise exception 'نام محصول اجباری است';
  end if;
  if coalesce(p_stock, 0) < 0 or coalesce(p_cost, 0) < 0
     or coalesce(p_mp, 0) < 0 or coalesce(p_hp, 0) < 0 then
    raise exception 'مقادیر نمی‌توانند منفی باشند';
  end if;

  insert into public.products (name, stock, hp, base_price)
  values (trim(p_name), p_stock, p_hp, p_cost + p_mp)
  returning id into v_id;

  insert into public.product_costs (product_id, cost, mp)
  values (v_id, p_cost, p_mp);

  return v_id;
end;
$$;

create or replace function public.update_product(
  p_id       uuid,
  p_name     text,
  p_stock    integer,
  p_archived boolean
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_mahdi() then
    raise exception 'دسترسی غیرمجاز';
  end if;
  if char_length(trim(coalesce(p_name, ''))) = 0 then
    raise exception 'نام محصول اجباری است';
  end if;
  if coalesce(p_stock, 0) < 0 then
    raise exception 'موجودی نمی‌تواند منفی باشد';
  end if;
  update public.products
     set name = trim(p_name), stock = p_stock, archived = p_archived
   where id = p_id;
  if not found then raise exception 'محصول پیدا نشد'; end if;
end;
$$;

-- Helia sets only her own profit (mp/cost stay untouched in product_costs)
create or replace function public.set_hp(p_id uuid, p_hp bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'دسترسی غیرمجاز';
  end if;
  if coalesce(p_hp, 0) < 0 then raise exception 'سود نمی‌تواند منفی باشد'; end if;
  update public.products set hp = p_hp where id = p_id;
  if not found then raise exception 'محصول پیدا نشد'; end if;
end;
$$;

-- Mahdi sets purchase cost + his profit for one product (upserts)
create or replace function public.set_cost(p_id uuid, p_cost bigint, p_mp bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.is_mahdi() then
    raise exception 'دسترسی غیرمجاز';
  end if;
  if coalesce(p_cost, 0) < 0 or coalesce(p_mp, 0) < 0 then
    raise exception 'قیمت نمی‌تواند منفی باشد';
  end if;
  if not exists (select 1 from public.products where id = p_id) then
    raise exception 'محصول پیدا نشد';
  end if;
  insert into public.product_costs (product_id, cost, mp)
  values (p_id, p_cost, p_mp)
  on conflict (product_id) do update set cost = excluded.cost, mp = excluded.mp;
end;
$$;

-- Bulk cost update for Mahdi.
-- p_mode = 'percent': new_cost = round(cost * (1 + p_value/100))
-- p_mode = 'fixed'  : new_cost = cost + p_value        (p_value may be negative)
create or replace function public.bulk_cost_update(
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
  if auth.uid() is null or not public.is_mahdi() then
    raise exception 'دسترسی غیرمجاز';
  end if;
  if p_mode not in ('percent', 'fixed') then
    raise exception 'نوع تغییر نامعتبر است';
  end if;
  if p_value is null then raise exception 'مقدار تغییر اجباری است'; end if;

  for v_row in
    select product_id, cost from public.product_costs where product_id = any(p_ids)
  loop
    if p_mode = 'percent' then
      v_new := round(v_row.cost * (1 + p_value / 100))::bigint;
    else
      v_new := round(v_row.cost + p_value)::bigint;
    end if;
    if v_new < 0 then v_new := 0; end if;
    update public.product_costs set cost = v_new where product_id = v_row.product_id;
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- ==========================================================================
--  RPC: create_order  (server-side calculation, atomic stock decrement)
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
  v_mp_sum       bigint := 0;
  v_cost_sum     bigint := 0;
  v_discount     bigint := coalesce(p_discount, 0);
  v_mahdi_disc   bigint;
  v_helia_disc   bigint;
  v_ship_fee     bigint;
  v_net          bigint;
  v_total        bigint;
  v_payout       bigint;
  v_owe          bigint;
  v_h_share      bigint;
  v_m_profit     bigint;
  v_post_fee     bigint;
  v_mult         numeric;
  v_step         bigint;
  v_status       text;
  v_order_id     uuid;
  v_priv_items   jsonb := '[]'::jsonb;
  v_out_items    jsonb := '[]'::jsonb;
  v_expected     integer := 0;
  v_seen         integer := 0;
  v_hist         jsonb;
  rec            record;
  v_qty          integer;
begin
  if v_uid is null then raise exception 'ابتدا وارد شوید'; end if;
  if not exists (select 1 from public.profiles where user_id = v_uid) then
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

  -- ---------- settings snapshot -----------------------------------------
  select coalesce((select value from public.settings where key = 'post_fee')::bigint, 190000),
         coalesce((select value from public.settings where key = 'snapp_multiplier')::numeric, 1.15),
         coalesce((select value from public.settings where key = 'rounding_step')::bigint, 5000)
    into v_post_fee, v_mult, v_step;

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

  -- ---------- lock products, validate stock, read prices ----------------
  for rec in
    select p.id, p.name, p.stock, p.hp, p.archived,
           coalesce(c.cost, 0) as cost, coalesce(c.mp, 0) as mp,
           (e->>'qty')::integer as qty
      from jsonb_array_elements(v_items) as e
      join public.products p on p.id = (e->>'product_id')::uuid
      left join public.product_costs c on c.product_id = p.id
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
    if rec.stock < v_qty then
      raise exception 'موجودی «%» کافی نیست (موجودی: %)', rec.name, rec.stock;
    end if;

    v_sub      := v_sub + v_qty * (rec.cost + rec.mp + rec.hp);
    v_base_sum := v_base_sum + v_qty * (rec.cost + rec.mp);
    v_hp_sum   := v_hp_sum + v_qty * rec.hp;
    v_mp_sum   := v_mp_sum + v_qty * rec.mp;
    v_cost_sum := v_cost_sum + v_qty * rec.cost;

    -- Helia-safe line snapshot: name, qty, base, hp (never cost/mp)
    v_out_items := v_out_items || jsonb_build_array(jsonb_build_object(
      'product_id', rec.id, 'name', rec.name, 'qty', v_qty,
      'base', rec.cost + rec.mp, 'hp', rec.hp));
    -- Mahdi-only line snapshot: cost + mp
    v_priv_items := v_priv_items || jsonb_build_array(jsonb_build_object(
      'product_id', rec.id, 'qty', v_qty, 'cost', rec.cost, 'mp', rec.mp));
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

  v_payout   := v_net + v_ship_fee;
  v_owe      := v_base_sum - v_mahdi_disc + v_ship_fee;
  v_h_share  := v_hp_sum - v_helia_disc;
  v_m_profit := v_mp_sum - v_mahdi_disc;

  -- invariant: every toman is either owed to Mahdi or kept by Helia
  if (v_owe + v_h_share) <> v_payout then
    raise exception 'خطای محاسباتی: سهم‌ها با پرداختی برابر نیستند';
  end if;
  if v_m_profit < 0 or v_h_share < 0 then
    raise notice 'هشدار: سود منفی برای یکی از طرفین';
  end if;

  v_hist := jsonb_build_array(jsonb_build_object(
    'status', v_status, 'at', now(), 'by', v_uid));

  -- ---------- insert order + private row + decrement stock ---------------
  insert into public.orders (
    customer, phone, address, postal_code, items, method, shipping_method,
    shipping_fee, snapp_multiplier, rounding_step, discount, discount_bearer,
    mahdi_discount, helia_discount, total, owe, h_share, payout,
    status, status_history, note
  ) values (
    trim(p_customer), trim(public.normalize_digits(p_phone)), trim(p_address), v_postal,
    v_out_items, p_method, p_shipping_method, v_ship_fee, v_mult, v_step,
    v_discount, p_discount_bearer, v_mahdi_disc, v_helia_disc,
    v_total, v_owe, v_h_share, v_payout, v_status, v_hist, coalesce(p_note, '')
  ) returning id into v_order_id;

  insert into public.order_private (order_id, cost_total, m_profit, items)
  values (v_order_id, v_cost_sum, v_m_profit, v_priv_items);

  for rec in
    select (e->>'product_id')::uuid as pid, (e->>'qty')::integer as q
      from jsonb_array_elements(v_out_items) as e
  loop
    update public.products set stock = stock - rec.q where id = rec.pid;
  end loop;

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
  if auth.uid() is null then raise exception 'ابتدا وارد شوید'; end if;
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
    if o.shipping_method = 'post' and char_length(trim(coalesce(p_tracking, ''))) = 0 then
      raise exception 'برای ارسال پستی کد رهگیری اجباری است';
    end if;
    update public.orders
       set status = 'shipped',
           tracking = case
             when char_length(trim(coalesce(p_tracking, ''))) > 0 then trim(p_tracking)
             else tracking end,
           status_history = status_history || public.order_history_entry('shipped', p_note)
     where id = p_order_id;
  else
    update public.orders
       set status = p_status,
           status_history = status_history || public.order_history_entry(p_status, p_note)
     where id = p_order_id;
  end if;
end;
$$;

create or replace function public.cancel_order(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  o record;
  e jsonb;
begin
  if auth.uid() is null then raise exception 'ابتدا وارد شوید'; end if;

  select * into o from public.orders where id = p_order_id for update;
  if not found then raise exception 'سفارش پیدا نشد'; end if;
  if o.status = 'cancelled' then return; end if;
  if o.status in ('shipped', 'delivered') then
    raise exception 'این سفارش ارسال شده و قابل لغو نیست؛ برای پیگیری سنجاق کنید';
  end if;

  -- restore stock (atomic: same transaction as the status change)
  for e in select * from jsonb_array_elements(o.items)
  loop
    update public.products
       set stock = stock + greatest(coalesce((e->>'qty')::integer, 0), 0)
     where id = (e->>'product_id')::uuid;
  end loop;

  update public.orders
     set status = 'cancelled',
         status_history = status_history || public.order_history_entry('cancelled', null)
   where id = p_order_id;
end;
$$;

-- Bulk helper for the Accounts screen.
-- p_target = 'settled' (from paid) | 'paid' (from awaiting_snapp)
create or replace function public.bulk_set_status(p_order_ids uuid[], p_target text)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_from text;
  v_count integer := 0;
  r record;
begin
  if auth.uid() is null then raise exception 'ابتدا وارد شوید'; end if;
  if p_target = 'settled' then v_from := 'paid';
  elsif p_target = 'paid'  then v_from := 'awaiting_snapp';
  else raise exception 'وضعیت مقصد نامعتبر است';
  end if;

  for r in
    select id from public.orders
     where id = any(p_order_ids) and status = v_from
     order by created_at
     for update
  loop
    update public.orders
       set status = p_target,
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
  if auth.uid() is null then raise exception 'ابتدا وارد شوید'; end if;
  update public.orders
     set tracking = left(trim(coalesce(p_tracking, '')), 60)
   where id = p_order_id;
  if not found then raise exception 'سفارش پیدا نشد'; end if;
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
  if auth.uid() is null then raise exception 'ابتدا وارد شوید'; end if;
  update public.orders
     set pinned = p_pinned,
         pin_note = case when p_pinned then left(coalesce(p_pin_note, ''), 300) else '' end,
         pinned_at = case when p_pinned then now() else null end
   where id = p_order_id;
  if not found then raise exception 'سفارش پیدا نشد'; end if;
end;
$$;

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
       and p.proname in ('add_product','update_product','set_hp','set_cost','bulk_cost_update',
                         'create_order','set_order_status','cancel_order',
                         'bulk_set_status','set_tracking','set_pin')
  loop
    execute format('revoke all on function public.%I(%s) from PUBLIC', f.proname, f.args);
    execute format('revoke all on function public.%I(%s) from anon', f.proname, f.args);
    execute format('revoke all on function public.%I(%s) from authenticated', f.proname, f.args);
    execute format('grant execute on function public.%I(%s) to authenticated', f.proname, f.args);
  end loop;
end $$;

-- Table privileges: only authenticated users. Row Level Security decides
-- which rows (and the RPCs above decide which columns) each role touches.
do $$
begin
  execute 'revoke all on all tables in schema public from anon';
  execute 'grant usage on schema public to anon, authenticated';
  execute 'grant select on all tables in schema public to authenticated';
  execute 'grant update on public.settings to authenticated';
  execute 'grant all on all tables in schema public to service_role';
exception when others then null; end $$;

-- ==========================================================================
--  Creating the two users
-- ==========================================================================
-- 1) Supabase Dashboard -> Authentication -> Users -> "Add user"
--    (email + password, "Auto confirm user" = ON). Create exactly two users.
-- 2) Then insert their profile rows (replace the UUIDs):
--
-- insert into public.profiles (user_id, role) values
--   ('<uuid of mahdi>', 'mahdi'),
--   ('<uuid of helia>', 'helia')
-- on conflict (user_id) do update set role = excluded.role;
--
-- Never give the frontend the service_role key.
