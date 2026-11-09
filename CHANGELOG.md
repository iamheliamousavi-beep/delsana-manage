Delsana-managent v6/v7 / migration 013 — Change Report
==================================================

Business rule: Snap Pay settles to the SHOP's account, always.
`owe` is the shop's entitlement («سهم مغازه») — NOT a transfer from the page.
The page's profit share inside Snap-paid goods money is «طلب پیج از مغازه»
(page_claim), collectable only while the order is paid/settled/shipped/delivered;
the shop's share inside the page's cash receipts is «بدهی پیج به مغازه»
(page_debt). The two accounts are NEVER netted — no combined cell / net balance
anywhere.

Per-order split (exact integer math; BigInt in JS, numeric half-up in SQL):
  shipSnap   = shipping_fee if shipping_payment_method = 'snapp' else 0
  net        = (owe − shipping_fee) + h_share
  goodsSnap  = snapp_deposit − shipSnap
  page_claim = 0               if net ≤ 0 or h_share ≤ 0 or goodsSnap ≤ 0
             = min(goodsSnap, round_half_up(h_share · goodsSnap / net)) otherwise
  page_debt  = owe − snapp_deposit + page_claim            (always ≥ 0)
Both are DERIVED per order (Calc.pageSplit / order_page_claim & order_page_debt);
nothing extra is stored per order, all stored money values keep their v5 meanings,
order_amounts math and the status machine are unchanged.

1. Files changed and purpose

- calc.js  (money math)
  * Public `Calc.pageSplit(o)` (claim/debt for any order shape) plus internal
    `splitClaim`, VERSION bumped 6 → 7 with a header comment noting v6/v7.
  * calcOrder derives page_claim / page_debt and extends invariant_ok
    (claim ≥ 0, debt ≥ 0, snapp_deposit − claim + debt === owe).
  * Exports `Calc.parseMoney` and `Calc.pageSplit`.
- db.js  (data layer)
  * App state gains `claims: { receipts: [], allocations: [] }`, cleared on signOut.
  * New `DB.loadClaims()` fetches receipts (desc by created_at) and allocations
    (asc by order_created_at).
  * `DB.recordPageClaimReceipt(amount, receivedOn, note, allocations)` and
    `DB.voidPageClaimReceipt(id, reason)` via `DB.rpc`.
  * `page_claim_receipts` + `page_claim_allocations` added to DB.subscribe realtime.
- screens.js  (UI: Accounts card, buckets, order card, summaries, CSV)
  * `claimsCard()` prepended to Accounts: «جمع طلب / دریافت‌شده / مانده» stats,
    awaiting-Snapp info line, filter tabs «مانده‌دار / تسویه‌شده / همه»
    (persisted in `claimsFilter`), per-invoice rows with claim / received /
    remaining + progress bar, «دریافت…» (auto FIFO oldest-first or manual
    per-invoice allocation with exact-sum validation) and «جزئیات» (receipt
    history + void), «نیاز به بررسی» mismatch section.
  * Bucket 2 = «بدهی پیج به مغازه»: paid orders with page_debt > 0; sub-list
    «بدون بدهی به مغازه» with per-row «آماده ارسال» via `singleAction`;
    empty text «بدهی پیج به مغازه ندارید ✓».
  * `bucketCard` supports rowValue / doneLabel / sub; helpers
    claimsReceivedFor, claimEligible, claimsBook, claimsReceiptLive,
    claimsReceiptsFor, claimsAutoAlloc, claimsCard, claimsInvoiceRow,
    claimsInvoiceDetails, claimsReceiptRow, openRecordReceipt, canWriteClaims().
  * Orders CSV appends `page_claim`, `page_debt`, `page_claim_received`;
    new «خروجی دریافتی‌ها (CSV)» button exports receipts.csv.
- app.js  (wiring): `DB.loadClaims()` added to refreshData's Promise.all
  (realtime + polling both go through refreshData).
- setup.sql  (final DB schema, fresh installs)
  * Comment fixes: owe = shop's entitlement (not a page transfer), payout =
    what Snapp Pay deposits into the shop's account, snapp_deposit = what Snap
    Pay settles to the shop.
  * Mirrors migration 013 in full; `admin_delete_order` refuses orders carrying
    allocations («ابتدا دریافتی مربوط را ابطال یا جابه‌جا کنید»).
- migrations/013_page_claims.sql  (idempotent upgrade)
  * `public.order_page_claim(o public.orders)` / `public.order_page_debt(...)`:
    immutable, exact `round(numeric)` half-up, never store per-order claim.
  * Tables `page_claim_receipts` (id, created_at, created_by, received_on,
    amount > 0, note, voided_at, voided_by) and
    `page_claim_allocations` (id, receipt_id, order_id, amount,
    unique(receipt_id,order_id), snapshot customer + order_created_at).
  * RLS select `using (public.is_member())`; NO insert/update/delete policies
    (writes only through RPCs).
  * Deferred constraint trigger asserting sum(allocations) = receipt.amount.
  * RPCs `record_page_claim_receipt` / `void_page_claim_receipt`: security
    definer, `set search_path = public`, revoke PUBLIC/anon/authenticated,
    grant authenticated (+ service_role), `notify pgrst, 'reload schema'`,
    only helia/admin may record/void. Manual mode validates eligibility,
    per-invoice remaining, exact sum, duplicates, future dates — Persian error
    messages; auto mode = FIFO `for update` ordered by created_at.
  * `void_page_claim_receipt` idempotent (reason appended to note), raises
    «دریافتی پیدا نشد» if missing.
- tests.html  (headless runner): new section ۷ `pageSplit` — T1–T10 fixed cases,
  shape parity (calcOrder result === stored-row shape), ≥500-combo seeded sweep
  (seed 14050507, LCG `(seed*1103515245 + 12345) % 2147483648`), invariants;
  column header «پرداختی به مغازه» → «سهم مغازه». 151 PASSED.
- tests/page_claims.sql  (SQL Editor): role gate (mahdi + non-member rejected,
  helia + admin allowed); ineligible orders never receive allocations; partial
  receipts; automatic FIFO incl. a receipt split across two invoices; manual
  exact-sum/over-allocation/duplicate/future-date rejections; void + idempotent;
  `admin_delete_order` guard message; `admin_restore_order`; over-received
  mismatch after admin edit; outbox count 0; RLS reads; 500-combo sweep asserting
  SQL functions return EXACTLY the JS values (same embedded tuples as tests.html).
  Rolled back; ends with `ALL PASSED`.
- format.ts + format.test.ts: `oweto_shop` → «سهم مغازه», «واریزی اسنپ‌پی»
  → «واریزی اسنپ‌پی (به مغازه)»; test expectations updated.
- sw.js: cache `delsana-v17` → `delsana-v18`.

2. Tolerance & rounding details

- BigInt half-up: `claim = Number((2n*num + den) / (2n*den))`, num = hShare·goodsSnapp,
  den = net; verified against T5 (claim 490,909 / debt 90,909) and T10
  (claim 63,462 / debt 478,462).
- SQL uses `least(goodsSnap, round(h_share * goodsSnap / net))` — numeric
  `round` = half-up for positives, identical to JS.
- page_debt ≥ 0 holds analytically: debt = C + shipCash − h_share + claim and
  goodsSnap ≤ net ⇒ claim ≤ h_share; no clamping anywhere.
- Rows with `fee_in_snapp = false` (legacy v4) keep working entirely unchanged;
  no stored money value, order_amounts math, or invariant is altered.

3. Legacy interaction

- All pre-013 orders: no receipts, fully «مانده‌دار» (no back-fill); the single
  proportional split rule applies everywhere.
- Receipts are recorded by page/admin only — shop is read-only on the ledger.
- An order with allocations cannot be deleted until its receipt is voided or
  re-allocated (FK ON DELETE RESTRICT + explicit guard).
- admin_restore_order keeps working; admin_update_order needs no reset logic;
  new RPCs emit no outbox / Telegram events.

4. Unchanged files

- ui.js — no logic changes (helpers reused: modal, segmented, withBusy,
  fmtMoney/fmtDate, etc.).
- Status flow (new → paid → settled → shipped → delivered, awaiting_snapp → paid,
  cancellation from new/awaiting_snapp/paid/settled).
- New-order status option «پرداخت شده (پول در حساب پیج)» unchanged.
- csv header names for existing columns unchanged.
- tests/mixed_payment.sql, tests/admin_edit_delete.sql untouched.

5. Checklist for rollout

- [x] CSV backup (orders + receipts ledger) before any migration
- [x] calc.js v7: pageSplit, derived fields, invariants, VERSION 7
- [x] screens.js: claims section, buckets, order card, summaries, CSV columns
- [x] migrations/013_page_claims.sql upgrade path (idempotent; drop/recreate
  functions pattern like earlier migrations)
- [x] setup.sql mirror (comments + migration body + admin_delete_order guard)
- [x] db.js: App.claims, loadClaims, record/void RPCs, realtime, signOut
- [x] app.js: loadClaims wired into refreshData Promise.all
- [x] tests.html section ۷ + header + sweep (headless runner 151 PASSED)
- [x] tests/page_claims.sql SQL suite (rolled back, ends ALL PASSED)
- [x] format.ts + format.test.ts label updates; `deno test` 9 PASSED
- [x] sw.js cache bump: delsana-v17 → delsana-v18
- [x] README §7 (§ two accounts), §8 (labels/buckets/CSV), §9 (assumptions 15/17
  + new 25/26), §12 (migration order incl. 013 «run before pushing the frontend»),
  §13 (page_claims.sql)
- [x] CHANGELOG prepend (this report)
- [ ] Run full integration on a dev server (optional: end-to-end receipt flow)
- [ ] Walk-through T5 as page: awaiting bucket → info line → «واریز شد به مغازه»
  → claim 490,909 → receipt 200,000 → remaining 290,909 → fully received → void
  → remaining returns

6. Changelog entry (brief)

```
## v6/v7 / migration 013 — Snap Pay settles to the shop; «طلب پیج از مغازه» ledger

- owe is the shop's entitlement («سهم مغازه»), never a page transfer; Snap Pay
  always settles to the shop's account.
- page_claim = min(goodsSnap, round_half_up(h_share · goodsSnap / net)) — the
  page's profit share inside Snap-paid goods money; page_debt = owe −
  snapp_deposit + page_claim. Derived per order (never stored); two accounts
  never netted.
- order_page_claim / order_page_debt SQL functions (immutable, exact numeric
  half-up); tables page_claim_receipts / page_claim_allocations with RLS
  select for members only; deferred trigger enforces sum(allocations) = amount.
- record_page_claim_receipt RPC (auto FIFO oldest-first when allocations
  omitted; manual per-invoice with exact-sum validation, Persian errors) and
  void_page_claim_receipt (idempotent); helia/admin only.
- admin_delete_order refuses orders with allocations.
- setup.sql + migrations/013_page_claims.sql mirror each other; run 013 before
  pushing the frontend, after exporting CSV backups (orders + receipts).
- calc.js VERSION 7 with Calc.pageSplit / Calc.parseMoney exports; tests.html
  section ۷ (T1–T10 + 500-combo sweep) and tests/page_claims.sql (rolled back,
  ALL PASSED).
- Legacy rows (fee_in_snapp = false) unchanged; no back-fill of old orders.
```

---

Delsana-managent v5 / migration 012 ΓÇö Change Report
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
  * New `parseCashPart(text)` ΓÇö allows 0 for cash amount.
  * New `snappInverseRound(amount, multiplier)` ΓÇö exact half-up round of amount/multiplier
    (via parseMultiplierRational; used by live autosuggest).
  * calcOrder mixed branch first checks `fee_in_snapp` (v5) vs legacy v4.
  * v5 mixed always computes: remainingGoods = net - C, expectedSnap = snappRound(remaining, mult, MIXED_ROUND),
    fee = C + P - net, booked amounts as above.
  * Returns new fields: cash_part, remaining_goods, expected_snapp, fee_in_snapp.
  * VERSION bumped to 6; header comment notes the model.
  * Legacy rows unchanged ΓÇö fee_in_snapp=false keeps the v4 path entirely.

- db.js  (payload & select)
  * loadOrders select now includes fee_in_snapp.
  * createOrder: added p_cash_part: payload.method === 'mixed'
    ? (payload.cash_part ?? 0) : null. This selects v5 vs legacy on server side.
  * Fee column fee_in_snapp is written true for fresh mixed orders, false for legacy.

- screens.js  (new-order form & UI, card & admin modal & reports)
  * New two-input form under "╪¬╪▒╪¬█î╪¿ combining" (mixed):
    - `#no-cash-part` ΓÇö "┘à╪¿┘ä╪║ ┘å┘é╪»█î/┌⌐╪º╪▒╪¬ ┘à╪┤╪¬╪▒█î (╪¬┘ê┘à╪º┘å)" (editable; default empty).
    - `#no-snapp-part` ΓÇö "┘à╪¿┘ä╪║ ╪º╪│┘å┘╛ΓÇî┘╛█î ┘à╪┤╪¬╪▒█î (╪¬┘ê┘à╪º┘å)" (kept, rounded to nearest 1000 suggestion).
    - Autosuggest between the two: typing cash ΓåÆ snapp suggestion rounded to 1000;
      typing snap ΓåÆ cash suggestion (using snappInverseRound).
    - Chips: "█▓█╡┘¬ ┘å┘é╪»█î / █╡█░┘¬ ┘å┘é╪»█î / █╖█╡┘¬ ┘å┘é╪»█î" fill cash part, then reΓÇæsuggest snapp.
    - Live summary rows for mixed v5:
      ΓÇó ┬½┘╛╪▒╪»╪º╪«╪¬ ┌⌐╪º┘ä╪º ┘å┘é╪»█î/┌⌐╪º╪▒╪¬ (┘à╪┤╪¬╪▒█î)┬╗
      ΓÇó ┬½┌⌐╪º┘ä╪º█î ╪¿╪º┘é█îΓÇî┘à╪º┘å╪»┘ç ╪¿╪▒╪º█î ╪º╪│┘å┘╛ΓÇî┘╛█î┬╗
      ΓÇó ┬½┘à╪¿┘ä╪║ ┘à┘ê╪▒╪» ╪º┘å╪¬╪╕╪º╪▒ ╪º╪│┘å┘╛ΓÇî┘╛█î┬╗
      ΓÇó ┬½┘╛╪▒╪»╪º╪«╪¬ ┌⌐╪º┘ä╪º ╪¿╪º ╪º╪│┘å┘╛ΓÇî┘╛█î (┘à╪┤╪¬╪▒█î╪î ╪┤╪º┘à┘ä ┌⌐╪º╪▒┘à╪▓╪»)┬╗
    - Card: v5 labels use "╪º╪│┘å┘╛ΓÇî┘╛█î ┌⌐╪º┘ä╪º (┘à╪┤╪¬╪▒█î╪î ╪┤╪º┘à┘ä ┌⌐╪º╪▒┘à╪▓╪»)" + "┘å┘é╪»█î ┌⌐╪º┘ä╪º (┘à╪┤╪¬╪▒█î)"; legacy keeps old labels.
    - Admin modal: prefill cash field only for v5 mixed rows (fee_in_snapp true);
      legacy rows show only the Snapp field.
    - Patch passes cash_part only when fee_in_snapp true.
    - Reports card adds fee line: "┌⌐╪º╪▒┘à╪▓╪» ╪º╪│┘å┘╛ΓÇî┘╛█î (╪º╪▓ ┘à╪┤╪¬╪▒█î): X ╪¬┘ê┘à╪º┘å".

- format.ts + format.test.ts (invoice DM builder)
  * Order type gains optional `fee_in_snapp: boolean | null`; absent = legacy row.
  * buildInvoice branches:
    v5 mixed: shows fee inside the Snapp part line; legacy separate.
    v5 cash part line "┘å┘é╪»█î / ┌⌐╪º╪▒╪¬ ┌⌐╪º┘ä╪º (┘à╪┤╪¬╪▒█î)" without the fee;
    legacy cash part line still includes the fee label.
  * Test suite now has v5 mixed invoices + legacy compatibility.

- tests.html  (headless runner + new v5 test section)
  * Legacy mixed (M1ΓÇôM9) remains in section 5 unchanged (fee_in_snapp false ΓåÆ legacy path).
  * New section 5╪¿: "┘╛╪▒╪»╪º╪«╪¬ ╪¬╪▒┌⌐█î╪¿█î ┘à╪»┘ä ╪¼╪»█î╪» (┌⌐╪º╪▒┘à╪▓╪» ╪»╪º╪«┘ä ╪º╪│┘å┘╛ΓÇî┘╛█î)" with 18 v5 test cases
    covering: owner scenario, full Snapp, 7.5M goods + cash, discount interaction,
    shipping routing, tolerance boundaries, error messages, inverse round,
    edge cases (cash ΓëÑ net, negative fee, snap 0, fractional etc.).
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
  * Adds column fee_in_snapp to orders (default false ΓåÆ no backfill needed).
  * Drops all overloads of order_amounts (dynamic pg_proc loop) and recreates with the
    new p_cash_part parameter; mirrors setup.sql signature exactly.
  * Drops the current 14-argument create_order (dynamic) and recreates 15-argument version;
    revokes/grants execute; counts check to ensure exactly 1 overload exists.
  * admin_update_order is simply CREATE OR REPLACE (signature unchanged).
  * Grants loop for order_amounts + create_order; NOTIFY pgrst.

- tests/mixed_payment.sql  (SQL-side assertion suite)
  * All legacy 13 test cases (OWNER/M1ΓÇôM9) now include the new p_cash_part = null
    positional argument, so they continue under the legacy path unchanged.
  * New v5 test cases (aΓÇôc) mirror the user's expected outcomes:
      a) 5.5M goods / 100k cash / 6.1M Snapp ΓåÆ fee 700k, deposit 5.4M, total 6.2M
      b) full Snapp 6,215,000 ΓåÆ fee 715k
      c) 7.5M goods / 5M Snapp ΓåÆ cash Γëê 3,075,000, covered 4,424,779
  * v5 error messages: expected-vs-entered Persian text (tolerance 5000), negative cash,
    negative fee, cash ΓëÑ net, multiplier out of range, snapp_part 0, etc.
  * Invariant sweep (500 combos) verifying all four invariants for each row.
  * Split-shipping cases (goods Snapp + shipping cash/snapp, never multiplied).
  * Old 13 examples unchanged; old-mixed legacy math still passes because p_cash_part null.
  * All error-message checks use exact SQLERRM comparison.

2. Tolerance & rounding details

- MIXED_TOLERANCE = 5000 (user-chosen over the originallyΓÇæplanned 2000).
- Suggestion amounts shown rounded to nearest 1000 via `MIXED_ROUND = 1000`.
- Inverse round (for cash suggestion from typed Snapp) uses exact BigInt rational
  halfΓÇæup: `floor((2┬╖P┬╖b + a) / (2a))` for multiplier a/b.
- The snappRound used in calcOrder is the existing exact BigInt implementation;
  SQL uses `round_to_step(remaining::numeric * p_mult, 1000)` ΓÇö parity is
  assumed as previously validated for pure Snapp rows.
- The fee (C + P ΓêÆ net) is guaranteed ΓëÑ 0 after validation; if a pair slips
  through (tiny remainingGoods Γëê 10k with a low P) the fee < 0 check throws
  a Persian message.

3. Legacy interaction

- All preΓÇæ012 orders keep `fee_in_snapp = false`; their displayed values,
  admin edits, and reports never change. The old `order_amounts` signature
  is kept alive in the legacy branch (no p_cash_part ΓåÆ legacy math).
- Admin can edit legacy mixed rows unchanged; the cash field is disabled/hidden.
- A v5 row can be switched to cashΓÇæonly via admin edit ΓÇö fee_in_snapp becomes false
  and the row keeps legacy math from that point on.
- No backΓÇæfill of existing rows was performed; the new column defaults to false,
  which is exactly the correct value for every preΓÇæexisting row.

4. Unchanged files

- ui.js ΓÇö no logic changes; label text in new field captions only.
- db.js loadOrders select addition only.
- orderSplit and snappDeposit helpers (unchanged; work on both models).
- Existing pure Snapp / pure Cash flows completely untouched.

5. Checklist for rollout

- [x] calc.js v5 branch logic (parseCashPart, snappInverseRound, MIXED_TOLERANCE 5000)
- [x] db.js payload & createOrder signature with p_cash_part
- [x] screens.js mixed form, autosuggest, live summary, card, admin modal, reports
- [x] format.ts invoice DM builder with v5 / legacy branching
- [x] format.test.ts v5 mixed + legacy + parsing additions
- [x] tests.html headless runner (139 tests PASSED) + v5 section + legacy M1ΓÇæM9 unchanged
- [x] setup.sql schema additions (orders column + order_amounts + create_order)
- [x] migrations/012_snap_fee_in_snapp.sql upgrade path (drop/recreate functions)
- [x] tests/mixed_payment.sql SQL test suite (legacy 13 updated + 6 v5 cases + sweep)
- [x] sw.js cache bump: 'delsana-v14' ΓåÆ 'delsana-v15' (PWA cache clear)
- [x] Node smoke harness PASSED all 34 test scenarios (aΓÇôf + tolerance + invariants)
- [ ] Verify git status: new/modified files staged + committed per plan
- [ ] Run full integration on a dev server (optional: one mixed order endΓÇætoΓÇæend)
- [ ] Publish changelog entry (below)

6. Changelog entry (brief)

```
## v5 / migration 012 ΓÇö Fee inside Snapp amount

- Mixed (split) payment now stores the Snapp fee INSIDE the Snapp part.
  Customer pays a cash part C (goods only) and a Snapp part P (already
  contains the fee on goods covered by Snapp).  Validation: |P - round1000((net-C)*mult)| Γëñ 5000.
- New DB column `fee_in_snapp` flags the model; new orders get true,
  legacy rows keep false (no backΓÇæfill).
- calc.js: MIXED_ROUND=1000, MIXED_TOLERANCE=5000, parseCashPart, snappInverseRound.
- db.js: createOrder gains p_cash_part selecting v5 vs legacy math.
- screens.js: twoΓÇæinput mixed form, autosuggest to nearest 1000,
  live summary rows, card labels via fee_in_snapp flag, reports fee line.
- format.ts & tests.html: v5 invoice labels, 18 new test cases, headless runner 139 PASSED.
- setup.sql + migrations/012: schema change & function recreation.
- Old invoices open/display correctly unchanged.
```
