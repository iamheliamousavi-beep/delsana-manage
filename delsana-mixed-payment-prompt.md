# TASK: Add a MIXED payment method (part Snapp Pay + part cash) to "Delsana Management"

You are a senior engineer working on an existing, deployed app (repo `iamheliamousavi-beep/delsana-manage`): vanilla HTML/CSS/JS frontend (`calc.js`, `db.js`, `ui.js`, `screens.js`, `app.js`, `sw.js`, `tests.html`), Supabase backend (`setup.sql`, `migrations/`), Deno Edge Functions (`supabase/functions/`). Read `README.md`, `CHANGELOG.md` and `delsana-master-prompt.md` first: they define the money model, conventions and tests you must keep.

Do NOT ask me questions. Where something is ambiguous, pick the most sensible option, record it under "Assumptions" in `README.md`, and continue. Money correctness is the single most important requirement of this task: every toman must be accounted for, JS and SQL must produce identical numbers, and nothing that works today may change.

---

## 0. HARD RULES

1. All user-facing text is Persian. Code, comments, README, CHANGELOG are English.
2. Do not change the behavior, formulas or stored values of existing `cash` and `snapp` orders. Old orders must still display and sum correctly after the migration.
3. The server recomputes everything inside `create_order`; client numbers are never trusted. `calc.js` (browser) and the SQL function (server) must give identical integers for identical inputs.
4. Integers only (toman). The only non-integer input is the Snapp multiplier, and its effect must be computed with exact integer arithmetic (section 3), never with a bare float multiply.
5. Keep existing internal identifiers (`mahdi`, `helia`, `h_share`, `owe`, status keys, existing RPC names, element ids). Display names stay «پیج» / «مغازه» / «ادمین».
6. No secrets in the repo (it is public). Do not touch `supabase/.temp/`.
7. After each phase run `tests.html` logic (see section 9). Never write "tests pass" unless you actually executed them; if you cannot execute something (for example SQL against a real Postgres), say so explicitly and mark it UNVERIFIED in the final report.
8. Bump the service worker cache (`sw.js`, currently `delsana-v12` → `delsana-v13`).

---

## 1. WHAT "MIXED" MEANS (read carefully, this is the contract)

A new payment method `mixed` («ترکیبی (نقدی + اسنپ‌پی)»). The seller enters ONE extra number, the **Snapp part** `S` (toman, integer).

- `S` is the part of the goods value (after discount, in ordinary cash-equivalent toman) that the customer pays through Snapp Pay. It is also exactly what Snapp Pay will deposit to the page account for this order.
- The rest of the goods value (`net − S`) is paid in cash/card, at the normal cash price (no markup).
- The Snapp multiplier (default from settings, per-order override allowed, exactly like a Snapp order today) applies ONLY to `S`. The customer therefore pays `S × multiplier` (rounded to `rounding_step`) on the Snapp side.
- Shipping (`post_fee` for post, 0 for courier) is always paid in the cash part and is never multiplied. (In a pure Snapp order the shipping is also not multiplied, so the arithmetic stays consistent with today.)

Example from the owner: an item priced 10 → customer pays 5 via Snapp Pay (plus the Snapp fee on that 5) and 5 in cash. Page receives 5 from Snapp and 5 in cash.

### Definitions (existing, unchanged)
`sub = Σ q·(base+hp)`, `net = sub − discount`, `ship = (post ? post_fee : 0)`, `payout = net + ship`, discount split by bearer (`helia`/`mahdi`/`split`, split gives `mahdi_discount = floor(D/2)`), `owe = Σ q·base − mahdi_discount + ship`, `h_share = Σ q·hp − helia_discount`. Invariant `owe + h_share == payout` still holds and is still asserted.

### Formulas for each method (existing ones must stay byte-for-byte identical in result)

| field | cash | snapp | mixed |
|---|---|---|---|
| `snapp_part` (new) | 0 | 0 | `S` |
| `snapp_charge` (new: customer pays via Snapp Pay) | 0 | `total` | `snappRound(S) ` |
| `cash_charge` (new: customer pays in cash/card) | `total` | 0 | `(net − S) + ship` |
| `total` (customer pays) | `net + ship` | `snappRound(net) + ship` | `snapp_charge + cash_charge` |
| Snapp deposit to page | 0 | `payout` | `S` |
| `payout` | `net + ship` | `net + ship` | `net + ship` |

where `snappRound(x) = roundToStep(x × multiplier, rounding_step)` computed exactly (section 3).

Invariants that must hold for EVERY order of every method, asserted in `calc.js`, in SQL, and in tests:
- `snapp_charge + cash_charge == total`
- `snapp_deposit + cash_charge == payout` (cash received in hand + Snapp deposit = everything the page ends up holding)
- `owe + h_share == payout`

Informational (derived, not stored): `snapp_fee = snapp_charge − S` for mixed orders («کارمزد اسنپ‌پی (از مشتری)»). The rounding difference and the fee belong to nobody, same rule as today.

### Validation for `mixed` (client message and server exception, same Persian text)
- `S` must be an integer ≥ 1: «مبلغ اسنپ‌پی باید عدد صحیح و حداقل ۱ باشد»
- `S` must be strictly less than `net`: «مبلغ اسنپ‌پی باید کمتر از مبلغ کالاها پس از تخفیف باشد؛ برای پرداخت کامل از روش اسنپ‌پی یا نقدی استفاده کنید»
- `snapp_charge` must be > 0 after rounding: «مبلغ اسنپ‌پی خیلی کم است؛ بعد از گرد کردن صفر می‌شود»
- NON-blocking warning flag `snapp_below_deposit` when `snapp_charge < S`: «مبلغ اسنپ‌پی مشتری کمتر از مبلغ تسویه می‌شود؛ مبلغ اسنپ‌پی را تغییر دهید» (can happen for small `S` because of rounding; show it as a warning alert like `negative_helia_share`, never block).
- For `cash` and `snapp`, `snapp_part` must be null/0, otherwise reject: «مبلغ اسنپ‌پی فقط برای پرداخت ترکیبی است».
- If the discount or the cart changes so that `S ≥ net`, the form shows the error live and the save button stays disabled. Never silently clamp or change `S`.

### Status and accounts
- A mixed order starts as `awaiting_snapp` (same flow as a Snapp order; `status` parameter must be null for mixed, like snapp). Assumption to document: the cash part is considered received at creation; only the Snapp part is outstanding.
- Accounts bucket «در انتظار تسویه اسنپ‌پی» includes mixed orders, and its sum and per-row amount use the **Snapp deposit** (`S` for mixed, `payout` for snapp), not `payout`/`total`. Show a small sub-label on mixed rows: «ترکیبی: اسنپ‌پی {S} + نقدی {cash_charge}».
- The 14-day stale-money warning applies to mixed orders in `awaiting_snapp` as it does for snapp.

---

## 2. WORKED EXAMPLES (verified with an independent exact-integer script; use them as tests)

Common: product `base` 500,000, `hp` 150,000 (unit 650,000), qty 1, `post_fee` 190,000, multiplier 1.15, `rounding_step` 5000, unless stated.

| # | scenario | net | S | snapp_charge | cash_charge | total | payout | owe | h_share | snapp_deposit |
|---|---|---|---|---|---|---|---|---|---|---|
| M1 | courier, no discount | 650,000 | 325,000 | 375,000 | 325,000 | 700,000 | 650,000 | 500,000 | 150,000 | 325,000 |
| M2 | post, no discount | 650,000 | 325,000 | 375,000 | 515,000 | 890,000 | 840,000 | 690,000 | 150,000 | 325,000 |
| M3 | post, discount 50,000 bearer `split` | 600,000 | 300,000 | 345,000 | 490,000 | 835,000 | 790,000 | 665,000 | 125,000 | 300,000 |
| M4 | courier, S on a rounding boundary (350,000 × 1.15 = 402,500 → 405,000, not 400,000) | 650,000 | 350,000 | 405,000 | 300,000 | 705,000 | 650,000 | 500,000 | 150,000 | 350,000 |
| M5 | post, multiplier override 1.2 | 650,000 | 325,000 | 390,000 | 515,000 | 905,000 | 840,000 | 690,000 | 150,000 | 325,000 |
| M6 | post, discount 50,001 bearer `split` (odd discount) | 599,999 | 325,000 | 375,000 | 464,999 | 839,999 | 789,999 | 665,000 | 124,999 | 325,000 |
| M9 | `base` 200,000 + `hp` 150,000, post, S 100,000 | 350,000 | 100,000 | 115,000 | 440,000 | 555,000 | 540,000 | 390,000 | 150,000 | 100,000 |

Warning case M7: unit 650,000 courier, S 6,000 → `snapp_charge` 5,000 (< S), `snapp_below_deposit = true`, total 649,000, still saved, invariants hold.
Error cases: M8 S 2,000 → `snapp_charge` 0 → rejected; S = 0, S = 650,000 (= net), S = 650,001, S = 1.5, S = −5 → rejected; method `cash` or `snapp` with `snapp_part` 100 → rejected; discount 100,000 + S 600,000 on net 550,000 → rejected.

Also keep the existing 13 examples of the master prompt passing unchanged (they now also assert the three new invariants).

---

## 3. EXACT ROUNDING (`snappRound`)

Add `Calc.snappRound(amount, multiplier, step)` in `calc.js`:
- Convert the multiplier to an exact rational from its decimal string (`String(mult)` → digits `a` and denominator `b = 10^decimals`), then compute `floor((2·amount·a + b·step) / (2·b·step)) · step` with integers (use `BigInt` when `2·amount·a` could exceed `Number.MAX_SAFE_INTEGER`). This equals Postgres `round(amount × mult / step) × step` (half rounds up for positives).
- Use it for the mixed Snapp part. Do NOT change how pure `snapp` orders compute today; instead add a test proving `Calc.snappRound(n, m, step) === Calc.roundToStep(n·m, step)` for the loop in section 9 so the two never diverge.
- Reject `multiplier ≤ 0` or `> 10`, `step ≤ 0`, non-finite input with a thrown Persian error.

---

## 4. `calc.js` CHANGES

- `METHODS = ['cash','snapp','mixed']`, `VERSION: 3`.
- `calcOrder` accepts `snapp_part` (only meaningful for `mixed`) and returns, in addition to all existing keys: `snapp_part`, `snapp_charge`, `cash_charge`, `snapp_deposit`, `snapp_fee`, `snapp_below_deposit`, `invariant_ok` (now covering all three invariants of section 1).
- Add `Calc.snappDeposit(order)` helper working on a stored order row (`cash` → 0, `snapp` → `payout`, `mixed` → `snapp_part`) so Accounts/Reports/Invoice use one definition.
- Validation and error texts exactly as in section 1. The thrown error for a broken invariant stays an internal error.
- `unitPrices` unchanged.

---

## 5. DATABASE (`migrations/008_mixed_payment.sql` + mirrored into `setup.sql`)

`setup.sql` must equal "all migrations applied". The migration is idempotent and begins with a header comment: "BEFORE running: export all orders as CSV from the app." Steps:

1. Widen `orders.method` check to `('cash','snapp','mixed')` (drop the auto-named `orders_method_check` if it exists, then add the new one; use the `do $$ … $$` pattern of migration 007).
2. `alter table public.orders add column if not exists snapp_part bigint not null default 0, add column if not exists snapp_charge bigint not null default 0, add column if not exists cash_charge bigint not null default 0;`
3. Backfill existing rows once, idempotently (only where the new columns are all still 0): `snapp_charge = total` for `snapp`, `cash_charge = total` for `cash`, `snapp_part = 0`.
4. Add constraints after the backfill: `snapp_charge + cash_charge = total` for every row, and `(method = 'mixed') = (snapp_part > 0)`.
5. New pure function `public.order_amounts(p_sub bigint, p_base_sum bigint, p_hp_sum bigint, p_discount bigint, p_bearer text, p_ship_fee bigint, p_method text, p_snapp_part bigint, p_mult numeric, p_step bigint)` (`immutable`, no auth, no table access) that returns every derived amount (`net, mahdi_discount, helia_discount, total, payout, owe, h_share, snapp_part, snapp_charge, cash_charge, snapp_deposit`) and raises the Persian errors of section 1 and the existing ones (`D > sub`, `goods_owe < 0`, invariant failures). `create_order` must call it instead of inline arithmetic, so JS and SQL each have exactly ONE implementation of the math. Use the existing `round_to_step(numeric, bigint)`.
6. `create_order`: add a LAST parameter `p_snapp_part bigint default null`. Because adding a parameter creates a second overload (which breaks PostgREST/RPC calls), first `drop function if exists public.create_order(jsonb, text, text, text, text, text, text, bigint, text, numeric, text, text);` then create the new 13-argument version, then redo the REVOKE/GRANT block for the new signature (`revoke … from public, anon; grant execute … to authenticated`). Verify afterwards that `select count(*) from pg_proc where proname = 'create_order'` is 1. Behavior: `p_method` accepts `mixed`; the multiplier override is accepted for `snapp` and `mixed`; initial status is `awaiting_snapp` for `snapp` and `mixed`; store `snapp_part`, `snapp_charge`, `cash_charge`; everything else unchanged.
7. Create `tests/mixed_payment.sql` — a script runnable in the Supabase SQL Editor without logging in (it only calls `order_amounts`): one `DO` block with `assert` statements for M1–M9, the error cases (use `begin … exception` blocks to confirm each raises), the 13 old examples, and the three invariants over a loop of generated inputs. It must end with a `raise notice 'ALL PASSED'`.

---

## 6. FRONTEND CHANGES (find every site: `grep -n "method\|snapp\|payout" *.js` — known sites below, but do not rely on the list alone)

**`db.js`**: add `snapp_part, snapp_charge, cash_charge` to the `loadOrders` select; `createOrder` passes `p_snapp_part: payload.snapp_part ?? null`.

**`ui.js`**: `methodLabel` returns «نقدی/کارت» / «اسنپ‌پی» / «ترکیبی (نقدی + اسنپ‌پی)». In `nextActions` keep the «پرداخت شد» label only for `cash`; mixed uses the same label as snapp.

**`screens.js` — new order form**
- Payment radio gets a third option «ترکیبی». For mixed: show the multiplier override (like snapp), hide the initial-status select (like snapp), and show a new input «مبلغ اسنپ‌پی (تومان)» with hint «بخشی از مبلغ کالاها (پس از تخفیف) که با اسنپ‌پی پرداخت می‌شود و اسنپ‌پی به حساب پیج واریز می‌کند». Parse with the existing `UI.parseInt10` (Persian digits, separators; fractional input is an error, not truncated silently — validate the raw text and reject `1.5`).
- Optional helper chips «۲۵٪ / ۵۰٪ / ۷۵٪» that fill the input once with `floor(net × p / 100)`; later cart changes never auto-update it.
- Live summary rows for mixed: مبلغ کالاها، تخفیف (با طرف)، هزینه ارسال، «پرداخت اسنپ‌پی (مشتری)» = `snapp_charge`، «کارمزد اسنپ‌پی (از مشتری)» = `snapp_fee`، «پرداخت نقدی (مشتری)» = `cash_charge`، «مبلغ قابل پرداخت مشتری» = `total`، «تسویه اسنپ‌پی به پیج» = `snapp_deposit`، پرداختی به مغازه، سهم پیج. Warnings: `negative_helia_share` (existing) and `snapp_below_deposit`.
- `saveOrder`: validate `S` client-side with the same messages, send `snapp_part` only for mixed, and extend the confirm dialog: «سفارش «X» به مبلغ T (اسنپ‌پی A + نقدی B) ثبت شود؟».
- `resetOrderForm` clears the new input and resets the radio.

**`screens.js` — orders list/card**: payment filter gets «ترکیبی». Money cells for mixed: «اسنپ‌پی (مشتری)», «نقدی (مشتری)», «تسویه اسنپ‌پی» (= `snapp_deposit`) plus the existing cells. CSV export: keep every existing column, add `snapp_part`, `snapp_charge`, `cash_charge`, and write `mixed` in the payment column.

**`screens.js` — accounts**: per section 1 (deposit amounts, sub-label, stale warning).

**`screens.js` — reports**: the cash-vs-Snapp card must stay correct with three methods. Counts per method (cash / snapp / mixed). Money legend by channel: `cashSum = Σ cash_charge`, `snappSum = Σ snapp_charge` (so a mixed order contributes to both) and a test/assert that `cashSum + snappSum == Σ total`. KPI cards and top-products logic stay unchanged.

**Telegram (`supabase/functions/_shared/format.ts` + `format.test.ts`)**: extend the `Order` type with the three new fields; `methodLabel` gets the mixed label; in `buildInvoice` for mixed print, after «💳 پرداخت: ترکیبی (نقدی + اسنپ‌پی)», the lines «اسنپ‌پی: {snapp_charge} تومان» and «نقدی: {cash_charge} تومان», then «💰 مبلغ کل مشتری: {total} تومان» and «تسویه اسنپ‌پی: {snapp_deposit} تومان». Cash and snapp invoices stay exactly as they are today. Check that `notify`, `send-invoice` and any other function that selects order columns include the new fields (a `select('*')` is fine; an explicit column list must be extended). Add Deno test cases (mixed invoice contains both parts and the settlement line; cash invoice has no Snapp lines).

**`sw.js`**: bump the cache name; no new files are added.

---

## 7. NON-GOALS
No stock/cost model changes, no changes to notification kinds or push text, no new roles, no per-payment-part status tracking (see the assumption in section 1), no changes to the post-list import.

---

## 8. DOCUMENTATION
- `README.md`: money-rules table gets the mixed column and the three invariants; "Assumptions" lists (1) the Snapp part is defined on the cash-equivalent goods value after discount and equals the Snapp deposit, (2) shipping is always in the cash part, (3) the cash part is treated as received at creation and mixed orders start as `awaiting_snapp`, (4) mixed requires `0 < S < net`. Add migration 008 to the upgrade order in §12 and describe `tests/mixed_payment.sql` in §13. Update the test counts you changed.
- `CHANGELOG.md`: a new "Unreleased — mixed payment" entry.

---

## 9. TESTS (must be added, executed, and reported)

`tests.html` (keep the existing style, all existing checks stay):
1. M1–M9 with the exact numbers of section 2, including the warning flag and every error case.
2. Invariants (`snapp_charge+cash_charge==total`, `snapp_deposit+cash_charge==payout`, `owe+h_share==payout`) for all three methods across the existing 13 cases AND a deterministic pseudo-random sweep of at least 5,000 combinations (random qty/base/hp, discount, bearer, shipping, multiplier from `[1.05,1.1,1.125,1.15,1.2,1.25]`, valid `S`).
3. Rounding parity loop: for `S = 1 … 3,000,000` (step 7) and each multiplier above with `rounding_step` 5000, `Calc.snappRound` equals a BigInt exact reference AND equals `Calc.roundToStep(S·m, 5000)`.
4. `Calc.snappDeposit` for each method.
5. Number parsing of the Snapp input (Persian digits, separators, `1.5` rejected).

`tests/mixed_payment.sql`: as described in section 5.7.

Deno: `deno test supabase/functions/_shared/format.test.ts`.

JS↔SQL parity: if you can run a Postgres (local, pglite, docker) do it: feed the same 1,000 deterministic random inputs to `Calc.calcOrder` and to `public.order_amounts` and diff every output column; report the count of mismatches (must be 0). If you cannot run Postgres, say so and mark SQL as UNVERIFIED instead of claiming it passes.

---

## 10. PHASES (verify and report after each)

1. `calc.js` (`snappRound`, mixed, invariants, `snappDeposit`) + all new `tests.html` checks green.
2. SQL: migration 008, `setup.sql`, `order_amounts`, new `create_order`, grants, `tests/mixed_payment.sql`.
3. `db.js`, `ui.js`, new-order form, live summary, save flow.
4. Orders list/card, CSV, Accounts, Reports.
5. Telegram invoice + Deno tests, `sw.js` cache bump.
6. README, CHANGELOG, final review: grep once more for any `method === 'snapp'` / `=== 'cash'` ternary that silently treats `mixed` as one of them; confirm old orders render; list anything not done and why.

## 11. FINAL REPORT FORMAT
For each numbered section above: DONE / PARTIAL / NOT DONE, one line each, plus the exact commands you ran for tests and their results, plus an explicit list of anything UNVERIFIED. List every file you changed.
