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
           last_actor = auth.uid(),
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
-- (9.1) set_pin attributes the pin to the partner who pressed it
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- (9.1) price changes are collected by the RPCs: one outbox row per call,
-- never one row per product.  Identical to the setup.sql definitions above.
-- ---------------------------------------------------------------------------
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
