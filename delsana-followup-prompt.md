# FOLLOW-UP TASK for "Delsana Management" — two changes

Repo: `iamheliamousavi-beep/delsana-manage` (vanilla JS PWA + Supabase + Deno Edge Functions).

- **PART A**: fix the money model of the MIXED payment method (customer's Snapp credit is a hard cap; the Snapp fee is paid in cash).
- **PART B**: give the admin role the power to edit or permanently delete any order and any product, at any time, with an audit trail.

The mixed-payment feature from the previous prompt (`delsana-mixed-payment-prompt.md`) is already implemented in the repo. Do NOT assume the code matches that prompt literally: first read the real current code (`calc.js`, `setup.sql`, `migrations/`, `db.js`, `ui.js`, `screens.js`, `supabase/functions/**`, `tests.html`, `tests/`, `README.md`, `CHANGELOG.md`), list what exists, and adapt. Where the previous prompt and this one disagree, THIS prompt wins. Also read `delsana-master-prompt.md` for the base money model.

Do NOT ask me questions. If something is ambiguous, choose the most sensible option, record it under "Assumptions" in `README.md`, and continue. Money correctness is the most important requirement.

---

## 0. HARD RULES

1. User-facing text is Persian; code, comments, README, CHANGELOG are English.
2. Existing `cash` and `snapp` orders keep their exact behavior and stored values. Totals of existing orders never change by any migration in this task.
3. Server recomputes all money; JS (`calc.js`) and SQL must produce identical integers. There must be exactly ONE SQL implementation of the order math (the pure function `public.order_amounts`, see A5) and it is reused by `create_order` and by the new admin edit RPC.
4. Integers only (toman). Rounding of the Snapp multiplier uses exact integer arithmetic (`Calc.snappRound` already exists from the previous task; keep it).
5. Keep internal identifiers (`mahdi`, `helia`, `h_share`, `owe`, status keys, existing RPC names, element ids). Display names stay «پیج» / «مغازه» / «ادمین».
6. Never commit secrets; do not touch `supabase/.temp/`.
7. Never claim a test passed unless you executed it. Anything you could not execute (e.g. SQL on a real Postgres) is reported as UNVERIFIED.
8. Bump the service-worker cache (`sw.js`) once at the end (currently `delsana-v13` or whatever it is now → +1).
9. Use the next free migration numbers (expected `009_…` for part A and `010_…` for part B). Every migration is idempotent and mirrored into `setup.sql` ("setup.sql = all migrations applied"). Each starts with a header comment: "BEFORE running: export all orders as CSV from the app."

---

# PART A — Mixed payment: the Snapp part is the customer's real Snapp charge

## A1. The bug (what the owner reported)
Customer has 5,000,000 Snapp credit and pays the rest in cash. The app currently shows the customer's Snapp payment as `5,000,000 × 1.15 = 5,750,000`, which exceeds the credit. That is wrong: the amount charged on Snapp Pay can never exceed what the seller entered.

## A2. The correct model (confirmed by the owner)
The seller enters `S` = **the exact amount the customer pays through Snapp Pay** (the customer's Snapp credit used). Then:

- `snapp_charge = S` exactly. It is never multiplied, never rounded, never increased.
- The Snapp fee on that part is `snapp_fee = max(0, snappRound(S) − S)` where `snappRound(S) = roundToStep(S × multiplier, rounding_step)` (exact integer math). The **customer pays this fee in cash**.
- Snapp deducts the fee from the amount it settles: `snapp_deposit = S − snapp_fee` (what lands in the page's bank account from Snapp).
- The rest of the goods and the shipping are paid in cash: `cash_charge = (net − S) + snapp_fee + shipping_fee`.
- `total = snapp_charge + cash_charge = net + shipping_fee + snapp_fee`. (For every non-clamped case this equals the old total, so the customer's overall price does not change; only the split between Snapp and cash does.)
- `payout = net + shipping_fee` (unchanged: it is what the page ends up holding in total, `snapp_deposit + cash_charge`).
- `owe`, `h_share`, discount split: unchanged formulas. The fee and the rounding difference still belong to nobody; they only move through the customer's cash.

Pure `snapp` and `cash` orders: unchanged. For them define the new stored fields as: `cash` → `snapp_part 0, snapp_fee 0, snapp_charge 0, cash_charge total, snapp_deposit 0`; `snapp` → `snapp_part 0, snapp_fee 0, snapp_charge total, cash_charge 0, snapp_deposit payout`.

Invariants asserted in `calc.js`, SQL (`order_amounts`), CHECK constraints and tests, for EVERY order of every method:
1. `snapp_charge + cash_charge = total`
2. `snapp_deposit + cash_charge = payout`
3. `owe + h_share = payout`
4. mixed only: `snapp_charge = snapp_part`, `snapp_deposit = snapp_part − snapp_fee`, `total = payout + snapp_fee`

Validation for `mixed` (client toast/alert and server exception use the same Persian text):
- `S` integer ≥ 1: «مبلغ اسنپ‌پی باید عدد صحیح و حداقل ۱ باشد»
- `S < net`: «مبلغ اسنپ‌پی باید کمتر از مبلغ کالاها پس از تخفیف باشد؛ برای پرداخت کامل از روش اسنپ‌پی یا نقدی استفاده کنید»
- `snapp_fee < S` (so the deposit is > 0): «کارمزد اسنپ‌پی از مبلغ اسنپ‌پی بیشتر می‌شود؛ ضریب را بررسی کنید»
- NON-blocking warning `snapp_fee_clamped` when `snappRound(S) < S` (tiny S): fee is clamped to 0; message «مبلغ اسنپ‌پی خیلی کم است؛ کارمزد صفر در نظر گرفته شد».
- REMOVE the old `snapp_below_deposit` flag/warning and the old error «مبلغ اسنپ‌پی خیلی کم است؛ بعد از گرد کردن صفر می‌شود» (a tiny S is now allowed). Remove the "snapp_charge must be > 0" rule.
- `snapp_part` for `cash`/`snapp` must be null/0 (existing rule stays).

## A3. Worked examples (verified with an independent exact-integer script, 12,036-case invariant sweep with 0 violations; use them as tests)
Default product `base` 500,000 + `hp` 150,000 (unit 650,000), qty 1, `post_fee` 190,000, multiplier 1.15, step 5000, unless stated.

| # | scenario | S | snapp_fee | snapp_charge | cash_charge | total | payout | snapp_deposit | owe | h_share |
|---|---|---|---|---|---|---|---|---|---|---|
| OWNER | base 8,000,000 + hp 2,000,000, courier, no discount | 5,000,000 | 750,000 | 5,000,000 | 5,750,000 | 10,750,000 | 10,000,000 | 4,250,000 | 8,000,000 | 2,000,000 |
| M1 | courier | 325,000 | 50,000 | 325,000 | 375,000 | 700,000 | 650,000 | 275,000 | 500,000 | 150,000 |
| M2 | post | 325,000 | 50,000 | 325,000 | 565,000 | 890,000 | 840,000 | 275,000 | 690,000 | 150,000 |
| M3 | post, discount 50,000 bearer `split` | 300,000 | 45,000 | 300,000 | 535,000 | 835,000 | 790,000 | 255,000 | 665,000 | 125,000 |
| M4 | courier (350,000×1.15 = 402,500 → 405,000) | 350,000 | 55,000 | 350,000 | 355,000 | 705,000 | 650,000 | 295,000 | 500,000 | 150,000 |
| M5 | post, multiplier override 1.2 | 325,000 | 65,000 | 325,000 | 580,000 | 905,000 | 840,000 | 260,000 | 690,000 | 150,000 |
| M6 | post, discount 50,001 `split` | 325,000 | 50,000 | 325,000 | 514,999 | 839,999 | 789,999 | 275,000 | 665,000 | 124,999 |
| M7 | courier, tiny S (clamped, warning) | 6,000 | 0 | 6,000 | 644,000 | 650,000 | 650,000 | 6,000 | 500,000 | 150,000 |
| M8 | courier, tiny S (clamped, warning) | 2,000 | 0 | 2,000 | 648,000 | 650,000 | 650,000 | 2,000 | 500,000 | 150,000 |
| M9 | base 200,000 + hp 150,000, post | 100,000 | 15,000 | 100,000 | 455,000 | 555,000 | 540,000 | 85,000 | 390,000 | 150,000 |

Error cases: S = 0, S = −5, S = 1.5, S = net, S > net; multiplier 2 with S 100,000 (fee = S → rejected); `cash`/`snapp` with `snapp_part` 100; discount larger than goods.
Key check for the owner's complaint: in OWNER the customer's Snapp charge is exactly 5,000,000 (never 5,750,000) and the 750,000 fee appears inside the CASH amount.

## A4. `calc.js`
- `calcOrder` returns (in addition to existing keys): `snapp_part, snapp_fee, snapp_charge, cash_charge, snapp_deposit, snapp_fee_clamped, invariant_ok` (all 4 invariants). Remove `snapp_below_deposit`.
- `Calc.snappDeposit(orderRow)` uses the stored `snapp_deposit` column when present (fallback: cash 0, snapp `payout`, mixed `snapp_part − snapp_fee`).
- Keep `Calc.snappRound`, `roundToStep`, `unitPrices` and all existing exports.

## A5. Database — migration `009_mixed_snapp_charge.sql` (+ `setup.sql`)
1. `alter table public.orders add column if not exists snapp_fee bigint not null default 0, add column if not exists snapp_deposit bigint not null default 0;`
2. Backfill idempotently, in this order, without ever changing `total`, `payout`, `owe`, `h_share`:
   - `cash` rows: `snapp_deposit = 0`, `snapp_fee = 0`.
   - `snapp` rows: `snapp_deposit = payout`, `snapp_fee = 0`.
   - legacy `mixed` rows (created with the old model: stored `snapp_charge = snappRound(S)`, `cash_charge = net − S + ship`), only where `snapp_charge <> snapp_part`: `snapp_fee = total − payout`, `snapp_charge = snapp_part`, `cash_charge = total − snapp_part`, `snapp_deposit = snapp_part − snapp_fee`. Verify with a `select` that for every legacy mixed row all 4 invariants hold afterwards; abort (raise exception) if any row would violate them.
3. Replace the constraints from the previous migration with ones for the 4 invariants (drop the old ones by name if they exist; add the new ones after the backfill).
4. Rewrite `public.order_amounts(...)` (pure, `immutable`, no auth, no table access) to implement section A2 and return `net, mahdi_discount, helia_discount, total, payout, owe, h_share, snapp_part, snapp_fee, snapp_charge, cash_charge, snapp_deposit, snapp_fee_clamped`; it raises the Persian errors of A2 and the existing ones (`D > sub`, `goods_owe < 0`, invariant failures). `create_order` already calls it (verify); adapt its INSERT to store `snapp_fee` and `snapp_deposit`. If `create_order`'s signature changes in any way, `drop function if exists` the old signature first, redo REVOKE/GRANT, and verify `select count(*) from pg_proc where proname='create_order'` = 1.
5. Rewrite `tests/mixed_payment.sql` for the new numbers (A3 + errors + a generated invariant loop + the 13 old examples), ending with `raise notice 'ALL PASSED'`.

## A6. Frontend / notifications (find every site with `grep -n "snapp\|payout\|cash_charge\|snapp_charge\|snapp_part" *.js supabase/functions/**/*.ts`)
- `db.js`: add `snapp_fee, snapp_deposit` to the `loadOrders` select.
- New-order form: input label «مبلغ اسنپ‌پی مشتری (تومان)» with hint «مبلغی که مشتری با اعتبار اسنپ‌پی خودش پرداخت می‌کند؛ کارمزد اسنپ‌پی جدا و نقدی از مشتری گرفته می‌شود». Live summary rows for mixed: مبلغ کالاها، تخفیف، هزینه ارسال، «پرداخت با اسنپ‌پی (مشتری)» = `snapp_charge`، «پرداخت نقدی (مشتری)» = `cash_charge` with a muted sub-line «شامل کارمزد اسنپ‌پی: {snapp_fee}»، «مبلغ قابل پرداخت مشتری» = `total`، «واریزی اسنپ‌پی به پیج» = `snapp_deposit`، پرداختی به مغازه، سهم پیج. Show the `snapp_fee_clamped` warning. The confirm dialog: «… (اسنپ‌پی A + نقدی B)».
- Order card: «اسنپ‌پی (مشتری)», «نقدی (مشتری، شامل کارمزد)», «واریزی اسنپ‌پی» = `snapp_deposit`.
- Accounts bucket «در انتظار تسویه اسنپ‌پی»: row amount and bucket sum use `snapp_deposit` (for `snapp` rows that equals `payout`, unchanged); mixed rows get the sub-label «ترکیبی: اسنپ‌پی {S} + نقدی {cash_charge}».
- Reports: `cashSum = Σ cash_charge`, `snappSum = Σ snapp_charge`, assert `cashSum + snappSum == Σ total`; the cash-vs-Snapp card shows these.
- CSV: keep all columns, add `snapp_fee`, `snapp_deposit`.
- Telegram invoice (`format.ts`, `format.test.ts`): for mixed print «اسنپ‌پی (مشتری): {snapp_charge}», «نقدی (مشتری، شامل کارمزد اسنپ‌پی {snapp_fee}): {cash_charge}», «💰 مبلغ کل مشتری: {total}», «واریزی اسنپ‌پی: {snapp_deposit}». Cash and snapp invoices unchanged. Make sure `notify`/`send-invoice` select the new columns if they list columns explicitly.

## A7. Tests for part A (execute and report)
`tests.html`: A3 table, errors, the 4 invariants for the 13 original examples + a deterministic pseudo-random sweep of ≥ 5,000 mixed cases (multipliers `[1.05,1.1,1.125,1.15,1.2,1.25]`, random qty/base/hp/discount/bearer/shipping/valid S), a regression test that `snapp_charge === S` in every mixed case, and the OWNER case. Deno tests for the invoice. `tests/mixed_payment.sql`. If you can run a Postgres (local/pglite/docker), diff `Calc.calcOrder` vs `public.order_amounts` on 1,000 random inputs (must be 0 mismatches); otherwise mark SQL UNVERIFIED.

---

# PART B — Admin can edit or delete any order and any product

Scope: ONLY the `admin` role (`public.is_admin()`; not `is_mahdi()` — the shop role must not get this). Everything is enforced in the database (RLS + `security definer` RPCs that check `is_admin()`), not only in the UI. Page and store users must not see any of the new buttons, and calling the RPCs as them must fail with «دسترسی غیرمجاز».

## B1. Audit log (migration `010_admin_edit_delete.sql` + `setup.sql`)
```sql
create table if not exists public.audit_log (
  id bigserial primary key,
  at timestamptz not null default now(),
  actor uuid not null,
  entity text not null check (entity in ('order','product')),
  entity_id uuid not null,
  action text not null check (action in ('edit','delete','restore')),
  before jsonb, after jsonb
);
alter table public.audit_log enable row level security;
-- select: admin only; no insert/update/delete policy (RPCs only)
```
Index on `(entity, entity_id, at desc)`. Every admin RPC below writes one row in the same transaction (`before` = full row as `to_jsonb(old)`, `after` = new row or null for delete).

## B2. Edit any order — RPC `admin_update_order`
`admin_update_order(p_order_id uuid, p_data jsonb) returns uuid`, `security definer`, `set search_path = public`, `revoke … from public, anon; grant execute … to authenticated`, first line `if not public.is_admin() then raise exception 'دسترسی غیرمجاز'`. Works on orders in ANY status including `shipped`, `delivered`, `cancelled`. `p_data` may contain any of:
- customer data: `customer, phone, address, postal_code, note` (same validation as `create_order`/`update_order_info`);
- `shipping_method`, `method` (`cash|snapp|mixed`), `snapp_part`, `discount`, `discount_bearer`, `tracking`;
- `status` (admin may set ANY of the 7 statuses, bypassing the normal flow; append a `status_history` entry with a note «تغییر توسط ادمین»);
- settings snapshot overrides: `shipping_fee, snapp_multiplier, rounding_step` (default: keep the order's own snapshot, NEVER the current global settings);
- `items`: full replacement array of lines `{product_id (nullable), name, qty, base, hp}`. The admin may edit the price snapshot of a line (base/hp) and may add a line from a live product (the UI prefills name/base/hp from the current product; the server just validates numbers, `qty ≥ 1`, `base ≥ 0`, `hp ≥ 0`, name not empty, at least one line). Archived or unavailable products are allowed here (admin override).

Behavior: load the row `for update`, merge the patch over the stored values, then recompute ALL money by calling `public.order_amounts(...)` with the merged values (same function as `create_order`; the raised Persian errors surface to the UI). Update `items, method, shipping_method, shipping_fee, snapp_*, discount, discount_bearer, mahdi_discount, helia_discount, total, owe, h_share, payout, snapp_part, snapp_fee, snapp_charge, cash_charge, snapp_deposit, status, status_history, tracking, customer fields` in ONE UPDATE with `last_actor = auth.uid()`. The CHECK constraints from A5 guarantee the invariants hold. Payment-method changes are allowed (e.g. cash → mixed); when the method changes and the admin did not pass a status, keep the current status (do not guess). Write the audit row. The normal `outbox` triggers will fire from the UPDATE; additionally insert one `order_edited` outbox row (payload `{changed: [list of changed field names]}`) so the other partners are told that the admin edited the invoice.

Never trust the client: unknown keys in `p_data` are rejected («فیلد نامعتبر»).

## B3. Delete any order — RPC `admin_delete_order`
`admin_delete_order(p_order_id uuid) returns void`, admin only. Hard delete (the owner wants it gone completely). In ONE transaction:
1. lock the row, write the audit row with the full `before` snapshot (this is the only copy, and powers restore, B6);
2. insert an `order_deleted` outbox row whose payload carries everything the notifier needs after the order is gone: `{customer, tg_channel_msg_id, total, status}` (the order row will not exist when `notify` runs);
3. mark all still-pending `outbox` rows of this order (`order_id = p_order_id and processed_at is null and kind <> 'order_deleted'`) as processed so `notify` does not retry an order that no longer exists;
4. delete the order.
There are no foreign keys to `orders` (verify with a grep of the schema; if one exists, handle it).

## B4. Edit and delete any product — RPCs `admin_update_product`, `admin_delete_product`
- `admin_update_product(p_id uuid, p_data jsonb)`: admin may change `name, base_price, hp, available, archived` in one call (the existing shop-only/page-only split stays for non-admin users, untouched). Validate like the existing RPCs; audit row. Existing orders are unaffected because they store price snapshots in `orders.items`. Price/availability notifications: reuse the existing triggers (`available` change already emits `availability_changed`); for a price change by the admin insert one `prices_changed {count: 1}` outbox row like `set_base_price` does.
- `admin_delete_product(p_id uuid) returns jsonb`: hard delete, audit row with `before`, returns `{deleted: true, referenced_by_orders: n}` where `n` = number of orders whose `items` contain this `product_id` (computed with `jsonb_path_exists` or `@>`; those orders keep their snapshots and stay fully readable). Also insert a `product_deleted` outbox row `{name}`.

## B5. UI (admin only; `App.isAdmin` or equivalent already exists — verify, otherwise add)
- **Order card**: buttons «ویرایش کامل» and «حذف سفارش» visible only to admin. «ویرایش کامل» opens a full-screen modal (reuse the new-order form components where possible): customer fields, status select (all 7), tracking, note, shipping, payment method (cash / snapp / mixed with the same `S` input and live summary as part A), discount + bearer, the three settings snapshots (collapsed under «تنظیمات این سفارش»), and an editable line list (qty, name, base, hp per line + «افزودن کالا از لیست»). The live summary uses `Calc.calcOrder` with the order's own snapshots; on save call `admin_update_order` and show server errors as toasts. A visible banner: «شما به‌عنوان ادمین در حال ویرایش یک سفارش ثبت‌شده هستید؛ همهٔ مبالغ دوباره محاسبه می‌شود».
- «حذف سفارش»: danger confirm that shows customer name, total and status, and requires typing the word «حذف» to enable the button («این کار سفارش را برای همیشه از همهٔ گزارش‌ها حذف می‌کند»). After success: toast «سفارش حذف شد»; reload orders; the card disappears (realtime handles other devices; also handle the case where a deleted order is open or highlighted by a deep link).
- **Product card**: admin sees «ویرایش کامل» (name, base price, hp, available, archived in one form) and «حذف کامل محصول». The delete confirm says how many orders reference it: «N سفارش از این محصول استفاده کرده‌اند؛ آن‌ها بدون تغییر می‌مانند»; same typed «حذف» confirmation.
- **Audit screen** (admin only): in Settings add a card «تاریخچه تغییرات ادمین» → list of the latest 100 `audit_log` rows (time in Jalali, entity, action, customer/product name, a short diff of changed fields for edits) with a button «بازگردانی» on `delete` rows (B6). Use `DB` wrappers that read via a `security definer` RPC `admin_list_audit(p_limit int)` (admin only), since the table has no client policies.
- `db.js` wrappers for all new RPCs; `ui.js` labels if needed; all icon-only buttons need `aria-label`.

## B6. Restore (small, but required because deletion is permanent)
`admin_restore_order(p_audit_id bigint)` and `admin_restore_product(p_audit_id bigint)`: admin only; re-insert the row from `before` of a `delete` audit entry with its ORIGINAL id (fail with «این مورد قبلاً بازگردانده شده یا وجود دارد» if the id exists), `last_actor = auth.uid()`, write a `restore` audit row. The restored order must pass all CHECK constraints (it will, it satisfied them when it was stored). Restoring does not re-send old Telegram messages; set `tg_channel_msg_id` to null on a restored order so the channel gets a fresh message from the normal `order_created` outbox row the INSERT trigger creates.

## B7. Notifications (Edge Function `notify` + `_shared/format.ts` + `format.test.ts`)
- New kinds: `order_edited`, `order_deleted`, `product_deleted`. Recipients: all linked partners except the actor (same rule as 8.1 of the master prompt, admin included in the "partners" like the other product events). They respect test mode («حالت تست») like every automatic event.
- DM texts: «✏️ فاکتور {customer} توسط ادمین ویرایش شد» (+ fields changed in Persian, max 6), «🗑 سفارش {customer} توسط ادمین حذف شد», «🗑 محصول «{name}» حذف شد». Push text stays lock-screen safe (customer name only, no amounts).
- Telegram channel: after `admin_update_order` the channel post must be edited when customer, status or tracking changed (it already shows those; make sure an edit of the customer name triggers `editMessageText` — the idempotency hash handles no-ops). For `order_deleted`, edit the channel post (use `payload.tg_channel_msg_id`) to the original text plus «🗑 این سفارش حذف شد» and do NOT try to load the order (it does not exist). If `tg_channel_msg_id` is null, send nothing to the channel.
- `notify` must never throw/retry-forever for a missing order: for the three new kinds it uses only the payload. Add Deno tests for the three DM texts and for the channel text of a deleted order.

## B8. Tests for part B (execute and report)
- `tests/admin_edit_delete.sql`, runnable in the Supabase SQL Editor: it impersonates users with `set local role authenticated; set local request.jwt.claims = '{"sub":"<uuid>"}'` against throw-away rows it creates itself and rolls back at the end (`begin; … rollback;`). It must prove: (1) page and store users get «دسترسی غیرمجاز» from every new RPC; (2) admin edits a `delivered` order's items and the totals and all 4 invariants are recomputed correctly (use two concrete numeric cases); (3) switching an order cash → mixed (use the OWNER case) gives the A3 numbers; (4) an unknown key in `p_data` is rejected; (5) delete writes an audit row, removes the order, queues `order_deleted`, and marks old pending outbox rows processed; (6) restore brings it back with the same id and a second restore fails; (7) product delete returns the right `referenced_by_orders` and old orders keep their snapshots. If it cannot run here, mark it UNVERIFIED and say so.
- `tests.html`: admin edit helper logic on the client (line list totals via `Calc.calcOrder`, the typed-«حذف» enable rule) with at least 6 checks.
- Manual checklist added to README §13 for part B (log in as each role; edit; delete; restore; notifications; deep link to a deleted order).

---

## DOCUMENTATION
`README.md`: update the money table and mixed definition (A2), add the admin section (what the admin can do, audit log, restore, the fact that deletion is permanent apart from restore from the audit log), add migrations 009 and 010 to the upgrade order in §12, document the new tests, add an "Assumptions" list (the Snapp part is the customer's Snapp charge; fee clamped to 0 for tiny parts; admin edits keep the order's own settings snapshot unless overridden; admin status override bypasses the flow and is logged). `CHANGELOG.md`: two entries, "Unreleased — mixed payment: Snapp part is the real Snapp charge" and "Unreleased — admin edit/delete with audit log".

## PHASES (verify and report after each)
1. `calc.js` + `tests.html` for part A.
2. Migration 009, `setup.sql`, `order_amounts`, `create_order`, `tests/mixed_payment.sql`.
3. Part A frontend, accounts, reports, CSV, Telegram invoice + Deno tests.
4. Migration 010: `audit_log`, admin RPCs (edit/delete/restore, products, list audit), `setup.sql`, `tests/admin_edit_delete.sql`.
5. Part B frontend (order edit modal, delete confirms, product admin, audit card) + `db.js`.
6. Part B notifications (`notify`, `format.ts`, Deno tests).
7. README, CHANGELOG, `sw.js` cache bump, final review: grep for any leftover `snapp_below_deposit`, any `method === 'snapp'` / `=== 'cash'` ternary that treats `mixed` as one of them, and any admin button visible to non-admin roles; confirm old orders (cash, snapp, legacy mixed) still render and sum the same.

## FINAL REPORT FORMAT
For each numbered section (A1–A7, B1–B8): DONE / PARTIAL / NOT DONE with one line each; the exact test commands you ran and their results; an explicit list of UNVERIFIED items; the list of every changed file.
