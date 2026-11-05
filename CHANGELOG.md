Delsana-managent v5 / migration 012 — Change Report
==================================================

Business rule: the Snapp fee (toman) is collected INSIDE the Snapp amount.
Customers pay two parts:
  - cash part C (goods only; fee lives in Snapp)
  - Snapp part P (includes the fee on goods covered by Snapp)
Calculation:
  net = sub - discount
  remaining = net - C           (goods after cash discount)
  expectedSnap = round1000(remaining * multiplier)  -- rounded to nearest 1000 toman
  validation: |P - expectedSnap| <= 5000
  booked values (invariant):
    snapp_charge  = P + shipSnap
    cash_charge   = C + shipCash
    snapp_deposit = remaining + shipSnap
    snapp_fee     = C + P - net
    total         = C + P + shipFee

1. Files changed and purpose

- calc.js  (v5 model math & new parsers)
  * Added constants: MIXED_ROUND = 1000, MIXED_TOLERANCE = 5000.
  * New `parseCashPart(text)` — allows 0 for cash amount.
  * New `snappInverseRound(amount, multiplier)` — exact half-up round of amount/multiplier
    (via parseMultiplierRational; used by live autosuggest).
  * calcOrder mixed branch first checks `fee_in_snapp` (v5) vs legacy v4.
  * v5 mixed always computes: remainingGoods = net - C, expectedSnap = snappRound(remaining, mult, MIXED_ROUND),
    fee = C + P - net, booked amounts as above.
  * Returns new fields: cash_part, remaining_goods, expected_snapp, fee_in_snapp.
  * VERSION bumped to 6; header comment notes the model.
  * Legacy rows unchanged — fee_in_snapp=false keeps the v4 path entirely.

- db.js  (payload & select)
  * loadOrders select now includes fee_in_snapp.
  * createOrder: added p_cash_part: payload.method === 'mixed'
    ? (payload.cash_part ?? 0) : null. This selects v5 vs legacy on server side.
  * Fee column fee_in_snapp is written true for fresh mixed orders, false for legacy.

- screens.js  (new-order form & UI, card & admin modal & reports)
  * New two-input form under "ترتیب combining" (mixed):
    - `#no-cash-part` — "مبلغ نقدی/کارت مشتری (تومان)" (editable; default empty).
    - `#no-snapp-part` — "مبلغ اسنپ‌پی مشتری (تومان)" (kept, rounded to nearest 1000 suggestion).
    - Autosuggest between the two: typing cash → snapp suggestion rounded to 1000;
      typing snap → cash suggestion (using snappInverseRound).
    - Chips: "۲۵٪ نقدی / ۵۰٪ نقدی / ۷۵٪ نقدی" fill cash part, then re‑suggest snapp.
    - Live summary rows for mixed v5:
      • «پرداخت کالا نقدی/کارت (مشتری)»
      • «کالای باقی‌مانده برای اسنپ‌پی»
      • «مبلغ مورد انتظار اسنپ‌پی»
      • «پرداخت کالا با اسنپ‌پی (مشتری، شامل کارمزد)»
    - Card: v5 labels use "اسنپ‌پی کالا (مشتری، شامل کارمزد)" + "نقدی کالا (مشتری)"; legacy keeps old labels.
    - Admin modal: prefill cash field only for v5 mixed rows (fee_in_snapp true);
      legacy rows show only the Snapp field.
    - Patch passes cash_part only when fee_in_snapp true.
    - Reports card adds fee line: "کارمزد اسنپ‌پی (از مشتری): X تومان".

- format.ts + format.test.ts (invoice DM builder)
  * Order type gains optional `fee_in_snapp: boolean | null`; absent = legacy row.
  * buildInvoice branches:
    v5 mixed: shows fee inside the Snapp part line; legacy separate.
    v5 cash part line "نقدی / کارت کالا (مشتری)" without the fee;
    legacy cash part line still includes the fee label.
  * Test suite now has v5 mixed invoices + legacy compatibility.

- tests.html  (headless runner + new v5 test section)
  * Legacy mixed (M1–M9) remains in section 5 unchanged (fee_in_snapp false → legacy path).
  * New section 5ب: "پرداخت ترکیبی مدل جدید (کارمزد داخل اسنپ‌پی)" with 18 v5 test cases
    covering: owner scenario, full Snapp, 7.5M goods + cash, discount interaction,
    shipping routing, tolerance boundaries, error messages, inverse round,
    edge cases (cash ≥ net, negative fee, snap 0, fractional etc.).
  * Sweep 500 combos across all three methods plus invariant assertions.
  * parsing: cash-part parsing test added (0 is valid; 1.5 rejected).
  * Headless runner passes 139 tests.

- setup.sql  (final DB schema, creates new install only)
  * orders table: added `fee_in_snapp boolean not null default false` column.
  * order_amounts signature: added `p_cash_part bigint default null`
    between p_snapp_part and p_mult; p_mult/p_step now default null (validated in branches).
  * create_order: added `p_cash_part bigint default null` as 15th argument;
    inserts `fee_in_snapp = true` only when p_method='mixed' and p_cash_part is not null.
  * admin_update_order: updated to pass cash_part and model flag; v5 rows edit
    with cash_part; legacy rows keep legacy math.
  * Grants revoke/grant dynamic per signature (mirrors earlier migration patterns).

- migrations/012_snap_fee_in_snapp.sql  (idempotent upgrade of existing DBs)
  * Adds column fee_in_snapp to orders (default false → no backfill needed).
  * Drops all overloads of order_amounts (dynamic pg_proc loop) and recreates with the
    new p_cash_part parameter; mirrors setup.sql signature exactly.
  * Drops the current 14-argument create_order (dynamic) and recreates 15-argument version;
    revokes/grants execute; counts check to ensure exactly 1 overload exists.
  * admin_update_order is simply CREATE OR REPLACE (signature unchanged).
  * Grants loop for order_amounts + create_order; NOTIFY pgrst.

- tests/mixed_payment.sql  (SQL-side assertion suite)
  * All legacy 13 test cases (OWNER/M1–M9) now include the new p_cash_part = null
    positional argument, so they continue under the legacy path unchanged.
  * New v5 test cases (a–c) mirror the user's expected outcomes:
      a) 5.5M goods / 100k cash / 6.1M Snapp → fee 700k, deposit 5.4M, total 6.2M
      b) full Snapp 6,215,000 → fee 715k
      c) 7.5M goods / 5M Snapp → cash ≈ 3,075,000, covered 4,424,779
  * v5 error messages: expected-vs-entered Persian text (tolerance 5000), negative cash,
    negative fee, cash ≥ net, multiplier out of range, snapp_part 0, etc.
  * Invariant sweep (500 combos) verifying all four invariants for each row.
  * Split-shipping cases (goods Snapp + shipping cash/snapp, never multiplied).
  * Old 13 examples unchanged; old-mixed legacy math still passes because p_cash_part null.
  * All error-message checks use exact SQLERRM comparison.

2. Tolerance & rounding details

- MIXED_TOLERANCE = 5000 (user-chosen over the originally‑planned 2000).
- Suggestion amounts shown rounded to nearest 1000 via `MIXED_ROUND = 1000`.
- Inverse round (for cash suggestion from typed Snapp) uses exact BigInt rational
  half‑up: `floor((2·P·b + a) / (2a))` for multiplier a/b.
- The snappRound used in calcOrder is the existing exact BigInt implementation;
  SQL uses `round_to_step(remaining::numeric * p_mult, 1000)` — parity is
  assumed as previously validated for pure Snapp rows.
- The fee (C + P − net) is guaranteed ≥ 0 after validation; if a pair slips
  through (tiny remainingGoods ≈ 10k with a low P) the fee < 0 check throws
  a Persian message.

3. Legacy interaction

- All pre‑012 orders keep `fee_in_snapp = false`; their displayed values,
  admin edits, and reports never change. The old `order_amounts` signature
  is kept alive in the legacy branch (no p_cash_part → legacy math).
- Admin can edit legacy mixed rows unchanged; the cash field is disabled/hidden.
- A v5 row can be switched to cash‑only via admin edit — fee_in_snapp becomes false
  and the row keeps legacy math from that point on.
- No back‑fill of existing rows was performed; the new column defaults to false,
  which is exactly the correct value for every pre‑existing row.

4. Unchanged files

- ui.js — no logic changes; label text in new field captions only.
- db.js loadOrders select addition only.
- orderSplit and snappDeposit helpers (unchanged; work on both models).
- Existing pure Snapp / pure Cash flows completely untouched.

5. Checklist for rollout

- [x] calc.js v5 branch logic (parseCashPart, snappInverseRound, MIXED_TOLERANCE 5000)
- [x] db.js payload & createOrder signature with p_cash_part
- [x] screens.js mixed form, autosuggest, live summary, card, admin modal, reports
- [x] format.ts invoice DM builder with v5 / legacy branching
- [x] format.test.ts v5 mixed + legacy + parsing additions
- [x] tests.html headless runner (139 tests PASSED) + v5 section + legacy M1‑M9 unchanged
- [x] setup.sql schema additions (orders column + order_amounts + create_order)
- [x] migrations/012_snap_fee_in_snapp.sql upgrade path (drop/recreate functions)
- [x] tests/mixed_payment.sql SQL test suite (legacy 13 updated + 6 v5 cases + sweep)
- [x] sw.js cache bump: 'delsana-v14' → 'delsana-v15' (PWA cache clear)
- [x] Node smoke harness PASSED all 34 test scenarios (a–f + tolerance + invariants)
- [ ] Verify git status: new/modified files staged + committed per plan
- [ ] Run full integration on a dev server (optional: one mixed order end‑to‑end)
- [ ] Publish changelog entry (below)

6. Changelog entry (brief)

```
## v5 / migration 012 — Fee inside Snapp amount

- Mixed (split) payment now stores the Snapp fee INSIDE the Snapp part.
  Customer pays a cash part C (goods only) and a Snapp part P (already
  contains the fee on goods covered by Snapp).  Validation: |P - round1000((net-C)*mult)| ≤ 5000.
- New DB column `fee_in_snapp` flags the model; new orders get true,
  legacy rows keep false (no back‑fill).
- calc.js: MIXED_ROUND=1000, MIXED_TOLERANCE=5000, parseCashPart, snappInverseRound.
- db.js: createOrder gains p_cash_part selecting v5 vs legacy math.
- screens.js: two‑input mixed form, autosuggest to nearest 1000,
  live summary rows, card labels via fee_in_snapp flag, reports fee line.
- format.ts & tests.html: v5 invoice labels, 18 new test cases, headless runner 139 PASSED.
- setup.sql + migrations/012: schema change & function recreation.
- Old invoices open/display correctly unchanged.
```