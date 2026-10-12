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
