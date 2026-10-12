# Changelog

Notable changes to **Delsana Management**. Version 2 implements the master prompt
(`delsana-master-prompt.md`); older history is listed at the end.

## Unreleased — mixed payment: Snapp part is the real Snapp charge

- The mixed Snapp part `S` is now the exact amount the customer pays through Snapp Pay
  (never multiplied, never rounded up): `snapp_charge = S`,
  `snapp_fee = max(0, snappRound(S) − S)` paid in cash,
  `cash_charge = (net − S) + snapp_fee + shipping_fee`,
  `snapp_deposit = S − snapp_fee`, `total = payout + snapp_fee`.
  Tiny parts clamp the fee to 0 with a non-blocking `snapp_fee_clamped` warning
  («مبلغ اسنپ‌پی خیلی کم است؛ کارمزد صفر در نظر گرفته شد»); `fee >= S` is rejected
  («کارمزد اسنپ‌پی از مبلغ اسنپ‌پی بیشتر می‌شود؛ ضریب را بررسی کنید»).
  The old `snapp_below_deposit` flag/warning and the
  «بعد از گرد کردن صفر می‌شود» error are removed.
- New columns `snapp_fee`/`snapp_deposit` (backfilled without touching totals:
  cash → 0/0, snapp → 0/`payout`, legacy mixed recomputed from `total − payout`),
  four invariants in CHECK constraints, pure `order_amounts` now returns
  `snapp_fee` + `snapp_fee_clamped` and is reused by `create_order`.
  Migration `009_mixed_snapp_charge.sql` mirrored into `setup.sql`; run it **before**
  pushing the frontend (export a CSV backup first).
- Frontend: «مبلغ اسنپ‌پی مشتری (تومان)» label + hint, live rows
  («پرداخت با اسنپ‌پی (مشتری)», «پرداخت نقدی (مشتری)» with
  «شامل کارمزد اسنپ‌پی: …», «واریزی اسنپ‌پی به پیج»), card cells
  («اسنپ‌پی (مشتری)», «نقدی (مشتری، شامل کارمزد)», «واریزی اسنپ‌پی»),
  Accounts bucket by `snapp_deposit`, CSV columns `snapp_fee`/`snapp_deposit`.
- Telegram invoice for mixed: «اسنپ‌پی (مشتری): …»,
  «نقدی (مشتری، شامل کارمزد اسنپ‌پی …): …», «واریزی اسنپ‌پی: …»; cash/snapp unchanged.
- Tests: `tests.html` §5 (OWNER/M1–M9, clamped warnings, fee error, 5,000-combo sweep
  with `charge === S`, parity loop, stored-column `snappDeposit`),
  `tests/mixed_payment.sql` rewritten (OWNER included), Deno invoice asserts,
  JS↔SQL parity by construction (same integer formulas; SQL run is UNVERIFIED here).

## Unreleased — admin edit/delete with audit log

- New `audit_log` table (admin reads via `admin_list_audit` only; writes via RPCs only)
  and seven admin-only RPCs: `admin_update_order` (any status, full money recompute
  through `order_amounts`, unknown keys rejected, `order_edited` outbox),
  `admin_delete_order` (hard delete + `order_deleted` outbox, old pending rows marked
  processed), `admin_update_product` / `admin_delete_product` (snapshots in old orders
  untouched, `referenced_by_orders` count), `admin_restore_order` /
  `admin_restore_product` (original id, fresh channel message for orders),
  `admin_list_audit`. Migration `010_admin_edit_delete.sql` mirrored into `setup.sql`.
- UI (admin only): «ویرایش کامل» full-screen order modal (banner, all 7 statuses,
  live summary on the order's own snapshots, editable line list, «افزودن کالا از لیست»),
  typed-«حذف» order/product deletes, product «ویرایش کامل», Settings
  «تاریخچه تغییرات ادمین» (latest 100, field diff, «بازگردانی»).
- Notifications: `order_edited` / `order_deleted` / `product_deleted` DMs + channel edit
  from the payload for deletions (never loads the missing row); test mode respected;
  pushes stay lock-screen safe. Deno tests 7–9.
- Tests: `tests/admin_edit_delete.sql` (throw-away rows, rolled back; UNVERIFIED here),
  `tests.html` §6 (6 admin client checks), manual checklist §13 items 17–19.

## Unreleased — mixed payment («ترکیبی»)

- New `mixed` payment method (part Snapp Pay + part cash): the seller enters the Snapp
  part `S` (`0 < S < net`); the customer pays `snappRound(S)` via Snapp plus
  `(net−S)+ship` cash; the page is settled exactly `S`. Exact integer math on both
  sides (`Calc.snappRound` rational+BigInt, SQL `round_to_step`); three invariants hold
  for every method.
- New columns `snapp_part`/`snapp_charge`/`cash_charge` (backfilled, constrained),
  pure `order_amounts` as the single server implementation, new 13-arg `create_order`
  (old overload dropped). Migration `008_mixed_payment.sql` mirrored into `setup.sql`;
  run it **before** pushing the frontend (the new order list needs the columns).
- Frontend: «ترکیبی» radio with Snapp-part input + ۲۵٪/۵۰٪/۷۵٪ chips, live part rows and
  `snapp_below_deposit` warning, save blocked while `S` is invalid, `(اسنپ‌پی + نقدی)`
  confirm text; list filter + card cells, CSV columns, Accounts by Snapp deposit,
  reports split by channel with `cashSum + snappSum == total` asserted.
- Telegram invoice lists both parts and the settlement for mixed; cash/snapp invoices
  unchanged. Service-worker cache `delsana-v13`.
- Tests: `tests.html` §5 (M1–M9, errors, 5,000-combo sweep, 2.57M-iteration parity loop,
  `snappDeposit`, input parsing — 96 checks green), `tests/mixed_payment.sql`
  (M1–M9, errors, old13, 500-combo sweep), Deno invoice asserts (6/6 green),
  1,000-input JS↔SQL parity with zero mismatches.

## Unreleased — admin role («ادمین»)

- New `admin` role: the current store login is promoted (email/password unchanged),
  with full access; the `mahdi` store slot stays empty until it gets credentials.
  Displayed as «ادمین» (`PARTY_LABEL`).
- `is_mahdi()` covers the admin everywhere the store has powers; new `is_admin()`
  gates admin-only controls. Migration `007_admin_role.sql` mirrored into `setup.sql`.
- The «حالت تست (بی‌صدا)» switch is admin-only: hidden in Settings for other users
  and enforced server-side (`settings_update` requires `is_admin()` for
  `telegram_paused`).
- Product-event notifications (price/availability) now reach every partner — admin,
  page and store; order-created push titles name the sender («از ادمین»).
  The actor is still never notified of their own change (8.1).
- Invoice button no longer reports success when the order is gone; manifest
  shortcuts use real `?view=` deep links. Service-worker cache `delsana-v12`.

## Unreleased — test mode («حالت تست»)

- Shared «حالت تست (بی‌صدا)» toggle in Settings → «اعلان‌ها»: while on, the `notify`
  Edge Function drops every automatic event (partner DM, channel post/edit, partner
  push) by marking claimed outbox rows processed without sending — nothing piles up
  for later. Both partners see the same switch (shared `settings` row).
- New `public.settings` key `telegram_paused` (`'0'`/`'1'`); `settings_update` RLS policy
  extended; migration `006_telegram_pause.sql` mirrored into `setup.sql`.
- `test-notify` and `send-invoice` intentionally ignore the flag (both target only the
  caller's own chat/devices), so you can still verify your own link mid-test.

## Unreleased — product edit toggle, channel post cleanup

- Product cards: name/price inputs and **ذخیره** live in a collapsed edit form behind one
  «ویرایش» button; «عدم موجودی»/«موجود شد» and «بایگانی» stay as separate one-tap buttons.
- Channel posts no longer carry the «باز کردن در اپ» button (DMs still do).
- Channel text is now customer, Jalali date, tracking code and `وضعیت: …` (no header line);
  every status change edits the post so the status line stays current. Redeploy `notify`.

## Unreleased — no-reinstall updates on iPhone

- Service-worker cache `delsana-v11`; the app forces an update check on every launch
  (`registration.update()`) and shows a «نسخه جدید آماده است» banner with a one-tap
  «اعمال به‌روزرسانی» reload when a new deploy takes control. Never delete/reinstall
  the Home Screen app — tapping the banner is enough.

## Version 2 — 2026-10-09

### Phase 9 — post-office list import
- New orders header button «ایمپورت لیست پست»: upload a post-office PDF (multiple files),
  pdf.js (`lib/pdfjs/`, vendored 3.11.174) extracts the text layer, `postimport.js` parses the
  parcels and matches them to post orders by recipient name + city, then a review table lets
  the user confirm rows before writing.
- Matching (5.1): pool = `shipping_method='post'` excluding cancelled; name 3 / 2.5 / 2 / 1,
  city 2 / 1, green when the best total ≥ 4.5 and the gap to the runner-up ≥ 1, yellow ≥ 2
  (preselected only when clearly best), red otherwise. Reversed (visual-order) names and the
  `لا/ال` swap are handled; top-5 candidates per row.
- Review table: verdict chip, per-row order select, checkbox (green pre-checked), warnings,
  existing-tracking rows behind an off-by-default «جایگزین شود» toggle, blocked duplicate
  rows, live counts in the footer. Optional «همزمان وضعیت سفارش‌های "آماده ارسال" را
  "ارسال‌شده" کن» (off by default) plus an opt-in tracking-code copy.
- Bulk save via the new `bulk_set_tracking(p_items jsonb, p_overwrite boolean,
  p_mark_shipped boolean)` RPC: UPDATE-only (no INSERT) so the `tracking_changed` outbox
  rows flow to the notification Edge Functions untouched; validation returns
  `{"updated":n,"skipped":[{order_id,reason}]}`; called in 200-row chunks. Only database
  change of this phase — one function, no tables/columns/indexes/RLS.
- Migration `004_bulk_set_tracking.sql` mirrored into `setup.sql` (grant list included);
  apply it in the Supabase SQL Editor before pushing (see README §12).
- `tests.html` section ۴) covers `postimport.js` (normalisation, parse, matching) with
  invented fixtures; service-worker cache bumped to `delsana-v10` (+`./postimport.js`,
  and every fetch path now returns a real offline `Response` instead of `undefined`).

### Phase 8 — cleanup and documentation
- `.gitignore` added (`.idea/`, `.DS_Store`, `node_modules/`); `.idea/` and the old
  `delsana-prompt.md` removed from the repository (they stay on disk).
- README rewritten for v2: schema and RPCs, money rules, screens, the complete notification
  setup (bot, secrets, functions, `app_private.config`, Web Push), *Upgrading* and the manual
  *Testing* checklist of the specification.
- Minor fixes (5.16): `window.scrollTo({behavior: 'auto'})`, accounts empty state now reads
  «بدهی بازی ندارید».
- `CHANGELOG.md` added; security checklist (section 11) re-verified.

### Phase 7 — Web Push, deep links, test-notify
- `sw.js` (cache `delsana-v5`): `push` always shows a visible Persian/RTL notification with
  icon and badge, `notificationclick` focuses the open app and navigates to the order,
  `pushsubscriptionchange` re-subscribes with the cached VAPID key; API requests are never
  cached.
- Settings → «اعلان‌ها» → «اعلان روی گوشی»: unsupported browser, iOS "add to the Home Screen"
  hint, permission `default` → «فعال‌سازی اعلان», `denied` → how to re-enable, active →
  «غیرفعال‌سازی» + «ارسال اعلان آزمایشی».
- Silent subscription re-check on every app start; `?view=…&order=…` deep links clear filters,
  scroll to the order and highlight it; optional home-screen badge.
- `test-notify` Edge Function (JWT on): test DM plus a push to every device, reporting what
  succeeded and dropping dead subscriptions.

### Phase 6 — Telegram linking and invoices
- `telegram-webhook` (`--no-verify-jwt`, secret header): `/start <token>` links the chat,
  `/stop`, `/help`, everything else ignored without leaking data to an unlinked chat.
- `send-invoice` (JWT on): sends the full invoice of `{order_id}` to the caller's own chat,
  answers `{ok:false, reason:'not_connected'}` otherwise.
- Settings: Telegram status, «اتصال تلگرام» (deep link `t.me/<bot>?start=<token>`) and
  «قطع اتصال»; order cards got «فاکتور در تلگرام من».

### Phase 5 — notifications
- Migration 003 / `setup.sql`: `outbox` + triggers (`order_created`, `status_changed`,
  `tracking_changed`, `pin_changed`, `availability_changed`, `prices_changed`), wake notifier,
  two pg_cron jobs (wake every 2 minutes, tracking reminder at 06:30 UTC), `telegram_links`,
  `telegram_chats`, `push_subscriptions`, `app_private.config`, the notification RPCs and the
  matching grants. `last_actor` is written by every order-mutating RPC.
- `notify` Edge Function: atomic `claim_outbox`, merge rule (one DM/push per order per batch),
  private-chat DMs, channel message create/edit with SHA-256 idempotency, `last_error` kept for
  the retry, `{processed, failed}` answer.
- `format.test.ts` (sections 12.3–12.6) and README section 10.

### Phase 4 — screens and flows
- Fixes 5.7–5.13 (courier name, discount report, «new» orders in حساب‌ها, ship dialog
  prefill, checkbox selection, typo, multiplier placeholder).
- Section 6: shipping without a tracking code, «منتظر کد رهگیری» pill/filter/bucket, «ثبت کد».
- Improvements 7.1–7.5 (edit customer data, stale-money warnings, products CSV, backup
  reminder, accessibility).

### Phase 3 — product model and display names
- Availability toggle («عدم موجودی» / «موجود شد»), archive instead of delete, product cards and
  order form per section 3.3, server-side rejection of unavailable products.
- Display names «پیج» and «مغازه» everywhere (roles stay `helia` / `mahdi`).
- `db.js` fixes 5.2/5.3 (settings update-only, post fee 0), `ui.js` parsing 5.14.

### Phase 2 — SQL security and simplified products
- `migrations/001_security.sql`: membership-scoped RLS (`is_member()`), validated settings,
  grant block that reports failures instead of swallowing them.
- `migrations/002_simplify_products.sql`: no cost, no stock, no `order_private`; products keep
  `base_price`, `hp`, `available`, `archived`.
- Matching `setup.sql`, `reset.sql` and README setup steps.

### Phase 1 — money model
- `calc.js` rewritten for v2 with float-safe Snapp rounding (`owe + h_share == total` /
  `== payout`), 13 money cases and the parsing cases in `tests.html` (37 checks).

## Version 1 — 2026-10-07

- First working app: sign-in, products, orders with status flow and pinning, حساب‌ها,
  reports with CSV export, settings, realtime sync and the PWA shell.
