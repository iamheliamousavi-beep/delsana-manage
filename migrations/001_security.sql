-- ==========================================================================
-- Migration 001 — security hardening
-- Master prompt sections 5.4 (membership-scoped RLS), 5.5 (settings values)
-- and 5.15 (no silent failures in the grant block).
--
-- The Supabase URL and the anon key are public.  A policy that only checks
-- `authenticated` therefore lets ANY signed-up stranger read every order and
-- product.  Every read policy must check that the caller has a row in
-- public.profiles (i.e. is one of the two partners).
--
-- Also: turn OFF "Allow new users to sign up" in the Supabase dashboard
-- (Authentication -> Sign In / Providers).  This migration is defence in
-- depth, not a replacement for that switch.
--
-- IDEMPOTENT — safe to run more than once.
-- ==========================================================================

-- --------------------------------------------------------------------------
-- helper: is the current user one of the two partners?
-- --------------------------------------------------------------------------
create or replace function public.is_member()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.profiles where user_id = auth.uid());
$$;

-- --------------------------------------------------------------------------
-- 5.4 — membership-scoped read policies
-- --------------------------------------------------------------------------
drop policy if exists products_select on public.products;
create policy products_select on public.products
  for select to authenticated
  using (public.is_member());

drop policy if exists orders_select on public.orders;
create policy orders_select on public.orders
  for select to authenticated
  using (public.is_member());

drop policy if exists settings_select on public.settings;
create policy settings_select on public.settings
  for select to authenticated
  using (public.is_member());

-- 5.5 — settings may only be written with a well formed value.
-- (There is no INSERT policy on purpose: the client updates existing rows.)
drop policy if exists settings_update on public.settings;
create policy settings_update on public.settings
  for update to authenticated
  using (public.is_member())
  with check (public.is_member() and (
    (key = 'snapp_multiplier' and value ~ '^[0-9]+(\.[0-9]+)?$') or
    (key in ('post_fee', 'rounding_step') and value ~ '^[0-9]+$')));

-- --------------------------------------------------------------------------
-- 5.4 — replace `auth.uid() is null` with `not public.is_member()`
--       in every RPC listed by the specification.
-- --------------------------------------------------------------------------

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
  if not public.is_member() then raise exception 'دسترسی غیرمجاز'; end if;

  select * into o from public.orders where id = p_order_id for update;
  if not found then raise exception 'سفارش پیدا نشد'; end if;
  if o.status = 'cancelled' then return; end if;
  if o.status in ('shipped', 'delivered') then
    raise exception 'این سفارش ارسال شده و قابل لغو نیست؛ برای پیگیری سنجاق کنید';
  end if;

  -- restore stock (atomic: same transaction as the status change)
  -- Migration 002 drops products.stock; the guard keeps this migration safe
  -- to re-run on a database where 002 has already been applied.
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'products'
                and column_name = 'stock') then
    for e in select * from jsonb_array_elements(o.items)
    loop
      update public.products
         set stock = stock + greatest(coalesce((e->>'qty')::integer, 0), 0)
       where id = (e->>'product_id')::uuid;
    end loop;
  end if;

  update public.orders
     set status = 'cancelled',
         status_history = status_history || public.order_history_entry('cancelled', null)
   where id = p_order_id;
end;
$$;

-- p_target = 'settled' (from paid) | 'paid' (from awaiting_snapp)
-- migration 003 extends the accepted targets.
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
  if not public.is_member() then raise exception 'دسترسی غیرمجاز'; end if;
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
  if not public.is_member() then raise exception 'دسترسی غیرمجاز'; end if;
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
  if not public.is_member() then raise exception 'دسترسی غیرمجاز'; end if;
  update public.orders
     set pinned = p_pinned,
         pin_note = case when p_pinned then left(coalesce(p_pin_note, ''), 300) else '' end,
         pinned_at = case when p_pinned then now() else null end
   where id = p_order_id;
  if not found then raise exception 'سفارش پیدا نشد'; end if;
end;
$$;

-- --------------------------------------------------------------------------
-- 5.4 — REVOKE / GRANT block, now including is_member()
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

-- --------------------------------------------------------------------------
-- 5.15 — table privileges.  A failure is reported (never swallowed silently)
-- and does not abort the rest of the migration.
-- --------------------------------------------------------------------------
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
