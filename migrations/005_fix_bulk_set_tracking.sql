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
    from (select t.id, t.code from unnest(v_ids, v_codes) as t(id, code)) s;

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
