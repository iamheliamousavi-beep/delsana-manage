# Changelog

Notable changes to **Delsana Management**. Version 2 implements the master prompt
(`delsana-master-prompt.md`); older history is listed at the end.

## Version 2 — 2026-10-09

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
