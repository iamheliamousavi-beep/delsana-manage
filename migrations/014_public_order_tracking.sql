-- ===========================================================================
-- 014_public_order_tracking.sql
--
-- «پیگیری سفارش» — the PUBLIC order-tracking page (track.html), prompt-6 v2.
--
-- Customers look up their own orders on a separate public page with
--   MOBILE NUMBER + NAME (the name they gave when ordering). No login.
--   The postal code is NOT used anywhere (many customers have none).
--
-- Privacy model (non-negotiable):
--   * The lookup requires BOTH values to match the SAME order: the full
--     mobile number (last 10 digits after normalization) AND name words.
--     Never name-only, never phone-only, never prefix matching.
--   * Customers never touch a table. They call ONE narrow security-definer
--     function, public.track_orders(text, text), that returns a whitelisted
--     set of fields only: registration time, item names + quantities, a
--     simplified stage (internal payment states are never exposed), the
--     shipping method, the tracking code (only post + shipped/delivered
--     with a non-blank code) and the shipped/delivered/cancelled dates.
--     It NEVER returns: customer name, phone, address, postal code,
--     prices/totals/discounts, payment method, notes, pin data, money
--     fields, raw status_history rows (they contain the user id `by` and
--     private notes), last_actor, order ids or any other id.
--   * "Not found" is one generic answer; it does not reveal which half of
--     the pair was wrong.
--   * Abuse protection: a per-IP limit (10 failures / 15 min) AND a
--     per-phone limit (8 failures / 60 min — this is what stops
--     name-guessing against one phone across any number of IPs). Only md5
--     hashes of the IP and of (phone + fixed salt) are stored.
--     Known accepted trade-off: an attacker who deliberately fails 8 times
--     for someone else's phone can lock that customer out for up to an
--     hour (they can DM instead).
--
-- Name matching rule (whole words, order-insensitive):
--   The normalized typed name is split into words; at least 1 word and at
--   least 2 characters in total (single-letter input -> "invalid"). Every
--   typed word must EQUAL one of the words of the normalized stored
--   `customer` (never a substring or prefix). So «مریم», «احمدی»,
--   «احمدی مریم» and «مریم احمدی» all match a stored «مریم احمدی», while
--   «مری», «احمد», «مریم رضایی» or «مریم احمدی‌نژاد» do not. Implemented
--   with arrays (string_to_array + @>), never LIKE '%…%'.
--   Digits typed inside a name are DROPPED (Persian names do not contain
--   digits; keeping them would only create mismatches).
--
-- BEFORE running: nothing (purely additive). Every statement below is
-- idempotent and safe to run twice. Mirrored into setup.sql (fresh
-- installs already contain the end state). Deploy order: run this file in
-- the Supabase SQL editor FIRST, then deploy the frontend (track.*).
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1) name normalizer (immutable, NOT callable by clients)
--    Explicit character lists everywhere — no locale-dependent regex
--    classes ([[:alpha:]], \w) for Persian text.
-- ---------------------------------------------------------------------------
create or replace function public.normalize_person_name(t text)
returns text
language plpgsql
immutable
parallel safe
as $$
declare
  v text;
begin
  -- 1) Persian/Arabic digits -> ASCII (normalize_digits), lowercase Latin
  v := lower(coalesce(public.normalize_digits(t), ''));

  -- 2) Arabic letters -> Persian equivalents: ي ك ة أ إ ٱ ؤ
  v := translate(v,
    E'\u064A\u0643\u0629\u0623\u0625\u0671\u0624',
    E'\u06CC\u06A9\u0647\u0627\u0627\u0627\u0648');

  -- 3) remove tatweel (U+0640), Arabic diacritics (U+064B-U+065F, U+0670)
  v := regexp_replace(v, E'[\u0640\u0670\u064B-\u065F]', '', 'g');

  -- 4) zero-width / bidi marks and NBSP + ASCII control whitespace -> space
  --    (U+200B U+200C U+200D U+200E U+200F, U+202A-U+202E, U+2066-U+2069,
  --     U+00A0, tab, newline, VT, FF, CR)
  v := translate(v,
    E'\u200B\u200C\u200D\u200E\u200F\u202A\u202B\u202C\u202D\u202E'
    || E'\u2066\u2067\u2068\u2069\u00A0\t\n\u000B\u000C\r',
    repeat(' ', 20));

  -- 5) punctuation and (ASCII) digits -> space. EXPLICIT list (documented:
  --    digits are dropped, see the header). Persian/Arabic digits were
  --    already converted in step 1.
  v := translate(v,
    '0123456789'
    || '.,،;؛:-_()[]{}«»!؟?/\|*+=@#$%^&~'
    || '"' || chr(39),
    repeat(' ', 44));

  -- 6) collapse whitespace and trim
  v := trim(regexp_replace(v, ' +', ' ', 'g'));

  return v;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2) the one narrow function the public page may call
-- ---------------------------------------------------------------------------
create or replace function public.track_orders(p_phone text, p_name text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_salt        constant text := 'delsana-track-v1|8Kq2mZ7f';
  v_headers     jsonb;
  v_xff         text;
  v_ip          text;
  v_ip_hash     text;
  v_phone10     text;
  v_phone_hash  text;
  v_norm_name   text;
  v_words       text[];
  v_fails       integer;
  v_orders      jsonb;
  v_found       boolean;
begin
  -- housekeeping: attempts older than a day are dead weight
  delete from public.track_attempts where at < now() - interval '1 day';

  -- ---------- phone: digits only, then the last 10 digits -----------------
  -- This makes 09121234567, +98 912 123 4567, 0098-912-123-4567,
  -- 912 123 4567 and Persian/Arabic digits all equal.
  v_phone10 := right(regexp_replace(public.normalize_digits(coalesce(p_phone, '')),
                                    '[^0-9]', '', 'g'), 10);
  if char_length(v_phone10) < 10 then
    v_phone10 := null;                       -- fewer than 10 digits
  end if;

  -- ---------- name: normalized words, >= 1 word and >= 2 chars in total ---
  v_norm_name := coalesce(public.normalize_person_name(p_name), '');
  v_words := string_to_array(v_norm_name, ' ');
  if char_length(v_norm_name) < 2 or array_length(v_words, 1) is null then
    v_words := null;
  end if;

  -- ---------- client IP (PostgREST puts the request headers here) ---------
  -- Only md5(ip) is stored. If no address is available the IP limit is
  -- skipped entirely (no shared bucket).
  begin
    v_headers := nullif(current_setting('request.headers', true), '')::jsonb;
  exception when others then
    v_headers := null;
  end;
  if v_headers is not null then
    v_xff := nullif(btrim(coalesce(v_headers ->> 'x-forwarded-for', '')), '');
    v_ip := case
      when v_xff is not null then btrim(split_part(v_xff, ',', 1))
      when nullif(btrim(coalesce(v_headers ->> 'cf-connecting-ip', '')), '') is not null
        then btrim(v_headers ->> 'cf-connecting-ip')
      when nullif(btrim(coalesce(v_headers ->> 'x-real-ip', '')), '') is not null
        then btrim(v_headers ->> 'x-real-ip')
      else null
    end;
  end if;
  if v_ip is not null then
    v_ip_hash := md5(v_ip);
  end if;

  -- phone is stored only as md5(last 10 digits + fixed app salt)
  if v_phone10 is not null then
    v_phone_hash := md5(v_phone10 || v_salt);
  end if;

  -- ---------- rate limits, BEFORE the lookup ------------------------------
  -- per IP: >= 10 failed attempts in the last 15 minutes
  if v_ip_hash is not null then
    select count(*) into v_fails
      from public.track_attempts
     where ip_hash = v_ip_hash and ok = false
       and at > now() - interval '15 minutes';
    if v_fails >= 10 then
      return jsonb_build_object('status', 'rate_limited');
    end if;
  end if;

  -- per phone: >= 8 failed attempts in the last 60 minutes
  -- (stops name-guessing against one phone number across any number of IPs)
  if v_phone_hash is not null then
    select count(*) into v_fails
      from public.track_attempts
     where phone_hash = v_phone_hash and ok = false
       and at > now() - interval '60 minutes';
    if v_fails >= 8 then
      return jsonb_build_object('status', 'rate_limited');
    end if;
  end if;

  -- ---------- invalid input ----------------------------------------------
  -- counts as a failure for the IP limit (phone_hash is null then)
  if v_phone10 is null or v_words is null then
    insert into public.track_attempts (ip_hash, phone_hash, ok)
      values (v_ip_hash, v_phone_hash, false);
    return jsonb_build_object('status', 'invalid');
  end if;

  -- ---------- the lookup: exact phone AND whole-word name -----------------
  select coalesce(jsonb_agg(x.j order by x.created_at desc), '[]'::jsonb)
    into v_orders
    from (
      select m.created_at, jsonb_build_object(
        'created_at', m.created_at,
        'items', coalesce((
                    select jsonb_agg(jsonb_build_object('name', i ->> 'name',
                                                        'qty',  i -> 'qty'))
                      from jsonb_array_elements(m.items) i
                 ), '[]'::jsonb),
        'stage', case m.status
                   when 'shipped'   then 'shipped'
                   when 'delivered' then 'delivered'
                   when 'cancelled' then 'cancelled'
                   -- new, awaiting_snapp, paid, settled: never expose the
                   -- internal payment states to the customer
                   else 'preparing'
                 end,
        'shipping_method', m.shipping_method,
        -- the code only for post + shipped/delivered + non-blank
        'tracking', case when m.status in ('shipped', 'delivered')
                          and m.shipping_method = 'post'
                          and nullif(btrim(m.tracking), '') is not null
                         then btrim(m.tracking) end,
        -- step dates from the LAST matching status_history entry
        -- (admin overrides can skip entries; null when absent)
        'shipped_at', (select (e.h ->> 'at')::timestamptz
                         from jsonb_array_elements(m.status_history)
                              with ordinality as e(h, ord)
                        where e.h ->> 'status' = 'shipped'
                        order by e.ord desc limit 1),
        'delivered_at', (select (e.h ->> 'at')::timestamptz
                           from jsonb_array_elements(m.status_history)
                                with ordinality as e(h, ord)
                          where e.h ->> 'status' = 'delivered'
                          order by e.ord desc limit 1),
        'cancelled_at', (select (e.h ->> 'at')::timestamptz
                           from jsonb_array_elements(m.status_history)
                                with ordinality as e(h, ord)
                          where e.h ->> 'status' = 'cancelled'
                          order by e.ord desc limit 1)
      ) as j
      from (
        select o.*
          from public.orders o
         where right(regexp_replace(public.normalize_digits(o.phone),
                                    '[^0-9]', '', 'g'), 10) = v_phone10
           and string_to_array(public.normalize_person_name(o.customer), ' ')
               @> v_words
         order by o.created_at desc
         limit 10
      ) m
    ) x;

  v_found := jsonb_array_length(v_orders) > 0;

  -- one attempt row after the lookup; successful lookups are not counted
  -- against the limits (they are stored with ok = true, never counted)
  insert into public.track_attempts (ip_hash, phone_hash, ok)
    values (v_ip_hash, v_phone_hash, v_found);

  if not v_found then
    -- one generic answer: never reveals whether phone or name was wrong
    return jsonb_build_object('status', 'not_found');
  end if;
  return jsonb_build_object('status', 'ok', 'orders', v_orders);
end;
$$;

-- ---------------------------------------------------------------------------
-- 3) attempts bookkeeping (RLS enabled, no policies = deny-all for clients)
-- ---------------------------------------------------------------------------
create table if not exists public.track_attempts (
  id         bigserial primary key,
  at         timestamptz not null default now(),
  ip_hash    text,
  phone_hash text,
  ok         boolean not null
);

alter table public.track_attempts enable row level security;

create index if not exists track_attempts_ip_idx    on public.track_attempts (ip_hash, at);
create index if not exists track_attempts_phone_idx on public.track_attempts (phone_hash, at);

alter table public.track_attempts
  add column if not exists phone_hash text;   -- no-op on fresh installs

revoke all on public.track_attempts from PUBLIC;
revoke all on public.track_attempts from anon, authenticated;
grant  all on public.track_attempts to service_role;

-- ---------------------------------------------------------------------------
-- 4) phone expression index (normalize_digits IS immutable, so the index
--    is legal). Phone is the selective half of the lookup.
--    NOTE: no postal-code index — the postal code is not used here.
-- ---------------------------------------------------------------------------
create index if not exists orders_phone10_idx
  on public.orders (right(regexp_replace(public.normalize_digits(phone),
                                         '[^0-9]', '', 'g'), 10));

-- ---------------------------------------------------------------------------
-- 5) helper functions that were still PUBLIC-granted by default and must
--    never be callable by clients (all callers are security-definer RPCs,
--    which run as the owner and keep EXECUTE regardless)
-- ---------------------------------------------------------------------------
revoke all on function public.order_history_entry(text, text)
  from PUBLIC, anon, authenticated;
revoke all on function public.assert_page_claim_receipt_sum()
  from PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6) grants — AFTER every revoke-block of setup.sql / earlier migrations
-- ---------------------------------------------------------------------------
revoke all on function public.track_orders(text, text) from PUBLIC;
revoke all on function public.track_orders(text, text) from anon, authenticated;
grant execute on function public.track_orders(text, text)
  to anon, authenticated, service_role;

revoke all on function public.normalize_person_name(text)
  from PUBLIC, anon, authenticated;

notify pgrst, 'reload schema';
