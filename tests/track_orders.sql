-- ===========================================================================
-- tests/track_orders.sql — public order tracking (migrations/014), SQL side.
--
-- Run the whole file in the Supabase SQL Editor. Everything runs inside one
-- transaction and is rolled back at the end, so no test data is left behind.
-- Ends with `raise notice 'ALL PASSED ...'`; any failure raises an
-- exception instead.
--
-- Covered: phone formats (Persian/Arabic digits, +98, 0098, dashes/spaces),
-- name matching rule (whole words, order-insensitive, ZWNJ/Arabic letters,
-- punctuation, invalid shapes), cross mismatches, newest-first order,
-- shared phone / different names, the 10-order cap, stage mapping for all
-- 7 statuses, tracking-code rules, history-derived dates, the LEAK test
-- (exact key set, no name/phone/address/postal/note/amount/by/id), anon
-- privileges, both rate limits (per-IP and per-phone) and housekeeping.
-- ===========================================================================

begin;

set_config('request.headers', '', true);   -- no client IP by default

do $test$
declare
  r     jsonb;
  t     text;
  t2    text;
  n     integer;
  v_ts  timestamptz;
  v_id  uuid;
  i     integer;
  f     record;
  v_oid oid;
begin

  -- ===================================================== A) phone formats =
  -- stored phone itself contains a space and a dash (create_order only
  -- normalizes digits, it keeps inner separators)
  insert into public.orders (customer, phone, items, method, shipping_method,
                             status, tracking, created_at)
    values ('مریم احمدی', '0912 123-4567',
            jsonb_build_array(jsonb_build_object('name', 'گلدان سرامیکی', 'qty', 2)),
            'cash', 'post', 'shipped', 'TRK-MAIN-111',
            timestamptz '2026-01-10 10:00:00+03:30');

  r := public.track_orders('09121234567', 'مریم');
  if r->>'status' <> 'ok' or jsonb_array_length(r->'orders') <> 1 then
    raise exception 'A1 plain phone'; end if;

  r := public.track_orders('+98 912 123 4567', 'مریم');
  if r->>'status' <> 'ok' then raise exception 'A2 +98 phone'; end if;

  r := public.track_orders('0098-912-123-4567', 'مریم');
  if r->>'status' <> 'ok' then raise exception 'A3 0098 phone'; end if;

  r := public.track_orders('912 123 4567', 'مریم');
  if r->>'status' <> 'ok' then raise exception 'A4 no-leading-zero phone'; end if;

  r := public.track_orders('۰۹۱۲۱۲۳۴۵۶۷', 'مریم');
  if r->>'status' <> 'ok' then raise exception 'A5 Persian digits'; end if;

  -- ==================================================== B) name positives =
  r := public.track_orders('09121234567', 'مریم');
  if r->>'status' <> 'ok' then raise exception 'B1 first name only'; end if;

  r := public.track_orders('09121234567', 'احمدی');
  if r->>'status' <> 'ok' then raise exception 'B2 last name only'; end if;

  r := public.track_orders('09121234567', 'مریم احمدی');
  if r->>'status' <> 'ok' then raise exception 'B3 full name'; end if;

  r := public.track_orders('09121234567', 'احمدی مریم');
  if r->>'status' <> 'ok' then raise exception 'B4 reversed'; end if;

  r := public.track_orders('09121234567', '  مریم   احمدی  ');
  if r->>'status' <> 'ok' then raise exception 'B5 extra spaces'; end if;

  -- ZWNJ (U+200C) between the words
  r := public.track_orders('09121234567', E'\u0645\u0631\u06CC\u0645\u200C \u0627\u062D\u0645\u062F\u06CC');
  if r->>'status' <> 'ok' then raise exception 'B6 ZWNJ'; end if;

  r := public.track_orders('09121234567', 'مريم احمدي');   -- Arabic ي
  if r->>'status' <> 'ok' then raise exception 'B7 Arabic yeh'; end if;

  r := public.track_orders('09121234567', 'مریم.');        -- punctuation
  if r->>'status' <> 'ok' then raise exception 'B8 punctuation'; end if;

  -- =================================================== C) name negatives =
  r := public.track_orders('09121234567', 'مری');
  if r->>'status' <> 'not_found' then raise exception 'C1 prefix مری'; end if;

  r := public.track_orders('09121234567', 'احمد');
  if r->>'status' <> 'not_found' then raise exception 'C2 prefix احمد'; end if;

  r := public.track_orders('09121234567', 'علی');
  if r->>'status' <> 'not_found' then raise exception 'C3 other name'; end if;

  r := public.track_orders('09121234567', 'مریم رضایی');
  if r->>'status' <> 'not_found' then raise exception 'C4 extra word'; end if;

  -- ZWNJ makes احمدی‌نژاد a separate word (نژاد is not in the stored name)
  r := public.track_orders('09121234567', E'\u0645\u0631\u06CC\u0645 \u0627\u062D\u0645\u062F\u06CC\u200C\u0646\u0698\u0627\u062F');
  if r->>'status' <> 'not_found' then raise exception 'C5 ezafe-like word'; end if;

  r := public.track_orders('912123456', 'مریم');           -- 9 digits
  if r->>'status' <> 'invalid' then raise exception 'C6 short phone'; end if;

  r := public.track_orders('', 'مریم');
  if r->>'status' <> 'invalid' then raise exception 'C7 empty phone'; end if;

  r := public.track_orders('09121234567', '');
  if r->>'status' <> 'invalid' then raise exception 'C8 empty name'; end if;

  r := public.track_orders('09121234567', 'م');            -- one letter
  if r->>'status' <> 'invalid' then raise exception 'C9 one-letter name'; end if;

  delete from public.track_attempts;   -- the failures above must not leak

  -- ============================== D) stored Arabic letters / ZWNJ, typed فارسی
  insert into public.orders (customer, phone, items, method, shipping_method, status)
    values (E'\u0645\u0631\u06CC\u0645\u200C \u0627\u062D\u0645\u062F\u06CC',  -- «مريم‌ احمدي» Arabic ي + ZWNJ
            '09130001111',
            jsonb_build_array(jsonb_build_object('name', 'شال', 'qty', 1)),
            'cash', 'post', 'new');

  r := public.track_orders('09130001111', 'مریم احمدی');
  if r->>'status' <> 'ok' then raise exception 'D Arabic/ZWNJ stored name'; end if;

  -- ================================================ E) half-wrong lookups =
  insert into public.orders (customer, phone, items, method, shipping_method, status)
    values ('مریم احمدی', '09140002222',
            jsonb_build_array(jsonb_build_object('name', 'کت', 'qty', 1)),
            'cash', 'courier', 'new');

  r := public.track_orders('09140002222', 'نام غلط');       -- right phone, wrong name
  if r->>'status' <> 'not_found' then raise exception 'E1 wrong name'; end if;

  r := public.track_orders('09140003333', 'مریم احمدی');    -- wrong phone, right name
  if r->>'status' <> 'not_found' then raise exception 'E2 wrong phone'; end if;

  delete from public.track_attempts;

  -- ============================================ F) ordering, sharing, cap =
  -- newest first
  insert into public.orders (customer, phone, items, method, shipping_method,
                             status, created_at)
    values ('ترتیب تست', '09150004444',
            jsonb_build_array(jsonb_build_object('name', 'قدیمی', 'qty', 1)),
            'cash', 'post', 'new', timestamptz '2026-02-01 00:00:00+00');

  insert into public.orders (customer, phone, items, method, shipping_method,
                             status, created_at)
    values ('ترتیب تست', '09150004444',
            jsonb_build_array(jsonb_build_object('name', 'جدید', 'qty', 1)),
            'cash', 'post', 'new', timestamptz '2026-03-01 00:00:00+00');

  r := public.track_orders('09150004444', 'ترتیب');
  if r->>'status' <> 'ok' or jsonb_array_length(r->'orders') <> 2 then
    raise exception 'F1 both orders'; end if;
  select o->'items'->0->>'name' into t
    from jsonb_array_elements(r->'orders') o limit 1;
  if t <> 'جدید' then raise exception 'F2 newest first'; end if;

  -- one phone number, two customers with different names: each sees only
  -- their own orders
  insert into public.orders (customer, phone, items, method, shipping_method, status)
    values ('مرد دانا', '09160005555',
            jsonb_build_array(jsonb_build_object('name', 'مردی', 'qty', 1)),
            'cash', 'post', 'new');

  insert into public.orders (customer, phone, items, method, shipping_method, status)
    values ('زن دانا', '09160005555',
            jsonb_build_array(jsonb_build_object('name', 'زنی', 'qty', 1)),
            'cash', 'post', 'new');

  r := public.track_orders('09160005555', 'مرد');
  if r->>'status' <> 'ok' or jsonb_array_length(r->'orders') <> 1
     or r->'orders'->0->'items'->0->>'name' <> 'مردی' then
    raise exception 'F3 shared phone, first customer'; end if;

  r := public.track_orders('09160005555', 'زن');
  if r->>'status' <> 'ok' or jsonb_array_length(r->'orders') <> 1
     or r->'orders'->0->'items'->0->>'name' <> 'زنی' then
    raise exception 'F4 shared phone, second customer'; end if;

  -- more than 10 orders of one customer -> exactly 10, newest first
  for i in 1..12 loop
    insert into public.orders (customer, phone, items, method, shipping_method,
                               status, created_at)
      values ('کماندو', '09170006666',
              jsonb_build_array(jsonb_build_object('name', 'سفارش-' || i, 'qty', 1)),
              'cash', 'post', 'new',
              timestamptz '2026-05-01 00:00:00+00' + (i * interval '1 day'));
  end loop;

  r := public.track_orders('09170006666', 'کماندو');
  if r->>'status' <> 'ok' or jsonb_array_length(r->'orders') <> 10 then
    raise exception 'F5 ten-order cap'; end if;
  select o->'items'->0->>'name' into t
    from jsonb_array_elements(r->'orders') o limit 1;
  if t <> 'سفارش-12' then raise exception 'F6 cap keeps newest'; end if;

  -- ==================================================== G) stage mapping =
  insert into public.orders (customer, phone, items, method, shipping_method, status)
    values ('وضعیت هفت', '09180007777',
            jsonb_build_array(jsonb_build_object('name', 'قلم-نو', 'qty', 1)),
            'cash', 'post', 'new');
  insert into public.orders (customer, phone, items, method, shipping_method, status)
    values ('وضعیت هفت', '09180007777',
            jsonb_build_array(jsonb_build_object('name', 'قلم-انتظار', 'qty', 1)),
            'cash', 'post', 'awaiting_snapp');
  insert into public.orders (customer, phone, items, method, shipping_method, status)
    values ('وضعیت هفت', '09180007777',
            jsonb_build_array(jsonb_build_object('name', 'قلم-پرداخت', 'qty', 1)),
            'cash', 'post', 'paid');
  insert into public.orders (customer, phone, items, method, shipping_method, status)
    values ('وضعیت هفت', '09180007777',
            jsonb_build_array(jsonb_build_object('name', 'قلم-تسویه', 'qty', 1)),
            'cash', 'post', 'settled');
  insert into public.orders (customer, phone, items, method, shipping_method, status)
    values ('وضعیت هفت', '09180007777',
            jsonb_build_array(jsonb_build_object('name', 'قلم-ارسال', 'qty', 1)),
            'cash', 'post', 'shipped');
  insert into public.orders (customer, phone, items, method, shipping_method, status)
    values ('وضعیت هفت', '09180007777',
            jsonb_build_array(jsonb_build_object('name', 'قلم-تحویل', 'qty', 1)),
            'cash', 'post', 'delivered');
  insert into public.orders (customer, phone, items, method, shipping_method, status)
    values ('وضعیت هفت', '09180007777',
            jsonb_build_array(jsonb_build_object('name', 'قلم-لغو', 'qty', 1)),
            'cash', 'post', 'cancelled');

  r := public.track_orders('09180007777', 'وضعیت هفت');
  if r->>'status' <> 'ok' or jsonb_array_length(r->'orders') <> 7 then
    raise exception 'G1 seven orders'; end if;

  for f in
    select * from (values
      ('new',            'قلم-نو',     'preparing'),
      ('awaiting_snapp', 'قلم-انتظار', 'preparing'),
      ('paid',           'قلم-پرداخت', 'preparing'),
      ('settled',        'قلم-تسویه',  'preparing'),
      ('shipped',        'قلم-ارسال',  'shipped'),
      ('delivered',      'قلم-تحویل',  'delivered'),
      ('cancelled',      'قلم-لغو',    'cancelled')
    ) x(st, nm, exp)
  loop
    select o->>'stage' into t
      from jsonb_array_elements(r->'orders') o
     where o->'items'->0->>'name' = f.nm;
    if t is distinct from f.exp then
      raise exception 'G2 stage of %: got %, want %', f.st, t, f.exp;
    end if;
  end loop;

  -- ==================================================== H) tracking code =
  insert into public.orders (customer, phone, items, method, shipping_method,
                             status, tracking)
    values ('رهگیری تست', '09190008888',
            jsonb_build_array(jsonb_build_object('name', 'کد-پست', 'qty', 1)),
            'cash', 'post', 'shipped', 'TRK-POST-111');

  insert into public.orders (customer, phone, items, method, shipping_method,
                             status, tracking)
    values ('رهگیری تست', '09190008888',
            jsonb_build_array(jsonb_build_object('name', 'کد-خالی', 'qty', 1)),
            'cash', 'post', 'shipped', '   ');

  insert into public.orders (customer, phone, items, method, shipping_method,
                             status, tracking)
    values ('رهگیری تست', '09190008888',
            jsonb_build_array(jsonb_build_object('name', 'کد-پیک', 'qty', 1)),
            'cash', 'courier', 'shipped', 'TRK-COURIER-222');

  insert into public.orders (customer, phone, items, method, shipping_method,
                             status, tracking)
    values ('رهگیری تست', '09190008888',
            jsonb_build_array(jsonb_build_object('name', 'کد-زود', 'qty', 1)),
            'cash', 'post', 'new', 'TRK-EARLY-333');

  r := public.track_orders('09190008888', 'رهگیری تست');
  if r->>'status' <> 'ok' or jsonb_array_length(r->'orders') <> 4 then
    raise exception 'H1 four orders'; end if;

  select o->>'tracking' into t from jsonb_array_elements(r->'orders') o
   where o->'items'->0->>'name' = 'کد-پست';
  if t <> 'TRK-POST-111' then raise exception 'H2 post+shipped+code'; end if;

  select o->>'tracking' into t from jsonb_array_elements(r->'orders') o
   where o->'items'->0->>'name' = 'کد-خالی';
  if t is not null then raise exception 'H3 blank code must be null'; end if;

  select o->>'tracking' into t from jsonb_array_elements(r->'orders') o
   where o->'items'->0->>'name' = 'کد-پیک';
  if t is not null then raise exception 'H4 courier must hide the code'; end if;

  select o->>'tracking' into t from jsonb_array_elements(r->'orders') o
   where o->'items'->0->>'name' = 'کد-زود';
  if t is not null then raise exception 'H5 not shipped must hide the code'; end if;

  -- =============================== I) step dates from status_history =====
  insert into public.orders (customer, phone, items, method, shipping_method,
                             status, status_history)
    values ('تاریخ تست', '09200009999',
            jsonb_build_array(jsonb_build_object('name', 'تاریخ-ارسال', 'qty', 1)),
            'cash', 'post', 'shipped',
            ('[{"status":"new","at":"2026-01-01T10:00:00+03:30","by":"f0e1d2c3-1111-2222-3333-444455556666","note":"HIST-MARKER"},' ||
             '{"status":"shipped","at":"2026-01-05T08:00:00+00:00","by":null},' ||
             '{"status":"shipped","at":"2026-01-06T09:00:00+03:30","by":null}]')::jsonb);

  insert into public.orders (customer, phone, items, method, shipping_method,
                             status, status_history)
    values ('تاریخ تست', '09200009999',
            jsonb_build_array(jsonb_build_object('name', 'تاریخ-بدون', 'qty', 1)),
            'cash', 'post', 'delivered', '[]'::jsonb);

  insert into public.orders (customer, phone, items, method, shipping_method,
                             status, status_history)
    values ('تاریخ تست', '09200009999',
            jsonb_build_array(jsonb_build_object('name', 'تاریخ-لغو', 'qty', 1)),
            'cash', 'post', 'cancelled',
            jsonb_build_array(jsonb_build_object(
              'status', 'cancelled', 'at', timestamptz '2026-02-02 14:00:00+03:30')));

  r := public.track_orders('09200009999', 'تاریخ تست');
  if r->>'status' <> 'ok' or jsonb_array_length(r->'orders') <> 3 then
    raise exception 'I1 three orders'; end if;

  -- LAST matching entry wins (two shipped entries -> the later one)
  select (o->>'shipped_at')::timestamptz into v_ts
    from jsonb_array_elements(r->'orders') o
   where o->'items'->0->>'name' = 'تاریخ-ارسال';
  if v_ts is distinct from timestamptz '2026-01-06 09:00:00+03:30' then
    raise exception 'I2 last shipped entry'; end if;
  select o->>'delivered_at' into t from jsonb_array_elements(r->'orders') o
   where o->'items'->0->>'name' = 'تاریخ-ارسال';
  if t is not null then raise exception 'I3 delivered_at null'; end if;

  -- no history -> all step dates null (admin override can skip entries)
  select o->>'shipped_at', o->>'delivered_at' into t, t2
    from jsonb_array_elements(r->'orders') o
   where o->'items'->0->>'name' = 'تاریخ-بدون';
  if t is not null or t2 is not null then
    raise exception 'I4 dates null without history'; end if;

  select (o->>'cancelled_at')::timestamptz into v_ts
    from jsonb_array_elements(r->'orders') o
   where o->'items'->0->>'name' = 'تاریخ-لغو';
  if v_ts is distinct from timestamptz '2026-02-02 14:00:00+03:30' then
    raise exception 'I5 cancelled_at'; end if;

  -- ======================================================= J) LEAK test ==
  -- the customer name and the item names share NO token, so a substring
  -- check really proves the name is gone; the money values satisfy the
  -- 4-invariant check (cash row: cash_charge = payout = total)
  insert into public.orders (customer, phone, address, postal_code, items,
                             method, shipping_method, status, tracking,
                             status_history, note, total, owe, cash_charge,
                             payout)
    values ('ظهور مارکر', '09390006666', 'ADDR-MARKER-42', 'POST-MARKER-77',
            jsonb_build_array(jsonb_build_object('name', 'قلم-ساده', 'qty', 2,
                                                 'base', 5555, 'hp', 6666)),
            'cash', 'post', 'shipped', 'TRK-LEAK-77',
            '[{"status":"shipped","at":"2026-01-06T09:00:00+03:30","by":"f0e1d2c3-1111-2222-3333-444455556666","note":"HIST-MARKER"}]'::jsonb,
            'NOTE-MARKER-9', 9876543, 9876543, 9876543, 9876543)
    returning id into v_id;

  r := public.track_orders('09390006666', 'ظهور');
  if r->>'status' <> 'ok' or jsonb_array_length(r->'orders') <> 1 then
    raise exception 'J1 lookup'; end if;

  -- the set of keys of every returned order is EXACTLY the whitelist
  select string_agg(k, ',' order by k) into t
    from jsonb_object_keys(r->'orders'->0) as kk(k);
  if t <> 'cancelled_at,created_at,delivered_at,items,shipping_method,shipped_at,stage,tracking' then
    raise exception 'J2 exact order keys: %', t; end if;

  select string_agg(k, ',' order by k) into t
    from jsonb_object_keys(r->'orders'->0->'items'->0) as kk(k);
  if t <> 'name,qty' then raise exception 'J3 exact item keys: %', t; end if;

  t := r::text;
  if position('مارکر' in t) <> 0 then raise exception 'J4 customer name leaked'; end if;
  if position('ظهور' in t) <> 0 then raise exception 'J5 customer name leaked'; end if;
  if position('9390006666' in t) <> 0 then raise exception 'J6 phone leaked'; end if;
  if position('09390006666' in t) <> 0 then raise exception 'J7 phone leaked'; end if;
  if position('ADDR-MARKER-42' in t) <> 0 then raise exception 'J8 address leaked'; end if;
  if position('POST-MARKER-77' in t) <> 0 then raise exception 'J9 postal leaked'; end if;
  if position('NOTE-MARKER-9' in t) <> 0 then raise exception 'J10 note leaked'; end if;
  if position('9876543' in t) <> 0 then raise exception 'J11 amounts leaked'; end if;
  -- (item base/hp prices are covered by J3: item keys are exactly name,qty)
  if position('f0e1d2c3-1111-2222-3333-444455556666' in t) <> 0 then
    raise exception 'J13 history user id leaked'; end if;
  if position('HIST-MARKER' in t) <> 0 then raise exception 'J14 history note leaked'; end if;
  if position(v_id::text in t) <> 0 then raise exception 'J15 order id leaked'; end if;
  -- the tracking code itself is allowed and present
  if position('TRK-LEAK-77' in t) = 0 then raise exception 'J16 tracking missing'; end if;

  -- ===================================================== K) rate limits ==
  -- per-IP limit: invalid inputs count as failures (no phone bucket)
  delete from public.track_attempts;
  perform set_config('request.headers', '{"x-forwarded-for":"203.0.113.77"}', true);
  for i in 1..10 loop
    r := public.track_orders('123', 'مریم');     -- invalid phone
    if r->>'status' <> 'invalid' then raise exception 'K1 invalid call %', i; end if;
  end loop;
  r := public.track_orders('09121234567', 'مریم');
  if r->>'status' <> 'rate_limited' then raise exception 'K2 11th IP attempt not limited'; end if;

  -- a different IP is unaffected
  perform set_config('request.headers', '{"x-forwarded-for":"198.51.100.5"}', true);
  r := public.track_orders('09121234567', 'مریم');
  if r->>'status' <> 'ok' then raise exception 'K3 other IP affected'; end if;

  -- per-phone limit: 8 failures (wrong names) from 8 DIFFERENT IPs
  delete from public.track_attempts;
  insert into public.orders (customer, phone, items, method, shipping_method, status)
    values ('زهرا درست', '09330001122',
            jsonb_build_array(jsonb_build_object('name', 'روسری', 'qty', 1)),
            'cash', 'post', 'new');

  for i in 1..8 loop
    perform set_config('request.headers',
                       '{"x-forwarded-for":"10.0.0.' || i || '"}', true);
    r := public.track_orders('09330001122', 'نام غلط');
    if r->>'status' <> 'not_found' then raise exception 'K4 phone call %', i; end if;
  end loop;

  -- the 9th attempt with the CORRECT name from a NEW IP is still blocked
  perform set_config('request.headers', '{"x-forwarded-for":"10.0.0.99"}', true);
  r := public.track_orders('09330001122', 'زهرا درست');
  if r->>'status' <> 'rate_limited' then
    raise exception 'K5 correct name not limited (name guessing not stopped)'; end if;

  -- a different phone is unaffected
  r := public.track_orders('09121234567', 'مریم');
  if r->>'status' <> 'ok' then raise exception 'K6 other phone affected'; end if;

  -- successful lookups do not consume the budget: 1 success + 7 failures
  -- is NOT enough to lock the phone out
  delete from public.track_attempts;
  perform set_config('request.headers', '{"x-forwarded-for":"10.9.9.9"}', true);
  r := public.track_orders('09121234567', 'مریم');
  if r->>'status' <> 'ok' then raise exception 'K7 success lookup'; end if;
  for i in 1..7 loop
    r := public.track_orders('09121234567', 'نام غلط');
    if r->>'status' <> 'not_found' then raise exception 'K8 failure call %', i; end if;
  end loop;
  r := public.track_orders('09121234567', 'مریم');
  if r->>'status' <> 'ok' then raise exception 'K9 successes were counted'; end if;
  select count(*) into n from public.track_attempts where ok = false;
  if n <> 7 then raise exception 'K10 failure rows: %', n; end if;
  select count(*) into n from public.track_attempts where ok = true;
  if n <> 2 then raise exception 'K11 success rows: %', n; end if;

  -- housekeeping: rows older than a day are purged inside the function
  insert into public.track_attempts (at, ip_hash, ok)
    values (now() - interval '2 days', md5('purge-test'), false);
  r := public.track_orders('09121234567', 'مریم');
  select count(*) into n from public.track_attempts where ip_hash = md5('purge-test');
  if n <> 0 then raise exception 'K12 old rows not purged'; end if;

  -- ==================================================== L) anon privileges
  select p.oid into v_oid
    from pg_proc p join pg_namespace nsp on nsp.oid = p.pronamespace
   where nsp.nspname = 'public' and p.proname = 'track_orders';
  if not has_function_privilege('anon', v_oid, 'EXECUTE') then
    raise exception 'L1 anon cannot execute track_orders'; end if;

  -- anon can execute NOTHING else in public (the three pure helpers
  -- normalize_digits / round_to_step / order_amounts were always PUBLIC)
  for f in
    select p.proname, p.oid
      from pg_proc p join pg_namespace nsp on nsp.oid = p.pronamespace
     where nsp.nspname = 'public'
       and p.proname not in ('track_orders', 'normalize_digits',
                             'round_to_step', 'order_amounts')
  loop
    if has_function_privilege('anon', f.oid, 'EXECUTE') then
      raise exception 'L2 anon can execute %', f.proname;
    end if;
  end loop;

  if has_table_privilege('anon', 'public.orders', 'SELECT') then
    raise exception 'L3 anon can select orders'; end if;
  if has_table_privilege('anon', 'public.track_attempts', 'SELECT') then
    raise exception 'L4 anon can select track_attempts'; end if;
  if has_table_privilege('anon', 'public.profiles', 'SELECT') then
    raise exception 'L5 anon can select profiles'; end if;
  if has_table_privilege('anon', 'public.outbox', 'SELECT') then
    raise exception 'L6 anon can select outbox'; end if;

  raise notice 'ALL PASSED — track_orders: phone/name matching, leak test,';
  raise notice 'ALL PASSED — stage/tracking/dates, privileges, rate limits, purge';
end
$test$;

rollback;
