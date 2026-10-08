-- ===========================================================================
-- 003_notifications.sql
--
-- Part A — order follow-up fixes (sections 5.9, 6, 7.1)
--   * set_order_status: shipping without a tracking code is allowed (6)
--   * set_tracking:     works on any non-cancelled order, records last_actor (6)
--   * bulk_set_status:  accepts target 'paid' from 'new' and 'awaiting_snapp' (5.9)
--   * update_order_info:new RPC for editing customer data (7.1)
--
-- Part B — notification plumbing (section 9.1) lives in this file too, so a
-- fresh install runs setup.sql while an existing install runs 001 + 002 + 003.
--
-- Every statement is idempotent (create or replace / create if not exists).
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- (6) shipping no longer requires the code to be known at that moment
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- (6) any non-cancelled order may receive (or clear) a code, and the change
--     is attributed to the partner who made it
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- (5.9) Accounts bulk buttons: money received for both cash and Snapp orders
-- ---------------------------------------------------------------------------
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
           status_history = status_history || public.order_history_entry(p_target, null)
     where id = r.id;
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- (7.1) edit customer data only — money and status are never editable here
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- Grants: the migration path runs 001/002 before this function exists, so the
-- grant loop has to run again after creating it (same list as setup.sql).
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
