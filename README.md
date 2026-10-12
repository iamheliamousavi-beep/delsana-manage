# Delsana Management

A small, production-ready PWA for the Delsana cosmetics business (Mahdi's wholesale shop + Helia's Instagram store).
Plain HTML/CSS/vanilla JavaScript, no framework, no build step, no `npm`. Backend is **Supabase** (Postgres + RLS + Realtime).

- Persian UI, RTL, light/dark theme, mobile-first (works on phone and desktop).
- Three roles: `admin` (full access, «ادمین»), `mahdi` (store, full access) and `helia` (page, own profit only).
- All money math lives in **one** pure file, `calc.js`, reused by the UI, by `tests.html`, and mirrored by the server-side `create_order` RPC.

---

## 1. Files

| File | Purpose |
|------|---------|
| `index.html` | App shell (boot, login, tab bar, view hosts) |
| `style.css` | Design system, RTL, light/dark themes |
| `app.js` | **Config object**, auth, navigation, realtime, service worker registration |
| `db.js` | Supabase data layer (queries + RPC calls) |
| `calc.js` | Pure money calculations (single source of truth) |
| `ui.js` | DOM helpers, formatting, toasts, dialogs, validation, CSV |
| `screens.js` | The seven screens (products, new order, orders, accounts, reports, settings, post-list import) |
| `postimport.js` | Pure PDF-text parsing + order matching for the post-list import (section 8.1) |
| `lib/pdfjs/` | Vendored pdf.js 3.11.174 (`pdf.min.js`, `pdf.worker.min.js`, `LICENSE`) |
| `setup.sql` | Schema, RLS policies, indexes, triggers and all RPCs |
| `manifest.json`, `sw.js` | PWA manifest + service worker (offline shell) |
| `icon.svg`, `icon-192.png`, `icon-512.png` | Icons |
| `tests.html` | Automated checks for the 10 worked money examples + invariants |
| `README.md` | This file |

---

## 2. Create the backend (≈10 minutes)

### 2.1 Create the Supabase project
1. Go to <https://supabase.com> → **New project** → pick a name and a strong database password.
2. Wait for the project to finish provisioning.

### 2.2 Run `setup.sql`
1. Supabase dashboard → **SQL Editor** → **New query**.
2. Paste the whole content of `setup.sql` → **Run**.
   You should see `Success. No rows returned`.
3. This creates: `profiles`, `products`, `orders`, `settings` — plus, for notifications,
   `outbox`, `telegram_links`, `telegram_chats`, `push_subscriptions` and `app_private.config`
   — together with all RLS policies, the indexes, the `orders`/`products` triggers, and every
   RPC: `create_order`, `order_amounts`, `set_order_status`, `cancel_order`, `bulk_set_status`, `set_tracking`,
   `set_pin`, `update_order_info`, `add_product`, `update_product`, `set_hp`, `set_base_price`,
   `set_availability`, `bulk_price_update`, `is_member`/`is_mahdi`/`my_role` and the
   notification RPCs described in section 10.

### 2.3 Create the users (admin + page; store slot stays empty)

1. Dashboard → **Authentication → Users → Add user**.
   - e.g. `admin@example.com` + a strong password → **Create user** (no need to confirm the email).
   - e.g. `helia@example.com` + a strong password → **Create user**.
   - Do **not** create the store user yet — the `mahdi` slot stays empty until the store needs its own login.
2. **There is no sign-up screen on purpose.** The app has exactly these users.

### 2.4 Give each user a role (required!)
The app reads the role from `profiles`. Run this in the SQL Editor with the real `user_id`
values from **Authentication → Users** (the UUID column):

```sql
insert into public.profiles (user_id, role) values
  ('<admin-user-uuid>', 'admin'),
  ('<helia-user-uuid>', 'helia')
on conflict (user_id) do update set role = excluded.role;
```

Existing database? Run `migrations/007_admin_role.sql` first, then promote the current
store login (email + password stay the same):

```sql
update public.profiles set role = 'admin'
 where user_id = (select id from auth.users where email = '<store email>');
```

Later, when the store needs its own login: create its Dashboard user, then:

```sql
insert into public.profiles (user_id, role) values ('<new-store-uuid>', 'mahdi');
```

Without this row the user can log in but will see: *"your profile is not registered"*.

### 2.5 Realtime
`setup.sql` already adds `orders`, `products` and `settings` to the `supabase_realtime` publication.
If your project disabled Realtime, enable it under **Database → Replication**.

---

## 3. Configure the frontend

Open `app.js` and fill the values at the very top:

```js
const CONFIG = {
  supabaseUrl: 'https://abcdefgh.supabase.co',      // Dashboard -> Project Settings -> API
  supabaseAnonKey: 'eyJ...'                          // the "anon public" key only
  telegramBotUsername: 'DelsanaBot',                 // the bot name without @ (notifications)
  vapidPublicKey: 'B...'                             // npx web-push generate-vapid-keys
};
```

Rules:
- **Never** put the `service_role` key in the frontend. Only the anon key.
- The app refuses to start (and shows a Persian message) while these still read `YOUR_…`.
- `telegramBotUsername` and `vapidPublicKey` are optional: without them the matching button in
  تنظیمات explains what is missing, everything else keeps working.

---

## 4. Deploy to GitHub Pages

1. Push these files to a GitHub repository.
2. Repository → **Settings → Pages → Source: Deploy from a branch** → `main` / `/(root)` → **Save**.
3. Open `https://<user>.github.io/<repo>/`.

Everything is referenced with **relative paths**, so a sub-path works out of the box.

---

## 5. Install as an app (PWA)

- **Android / Chrome:** open the site → menu → *Add to Home screen* / *Install app*.
- **Windows / Edge or Chrome:** address-bar *Install* icon → *Install*.
- The service worker caches the static shell: after the first visit the app opens **offline**
  (data needs a connection; Supabase API calls are never cached).

---

## 6. Verify the money rules

Open `tests.html` in a browser. It runs every worked example from the specification (the money
cases of section 2, the rounding regressions, the error case and the number-parsing cases of
5.14, plus the mixed-payment cases OWNER/M1–M9, error cases, a 5,000-combo invariant sweep, the
rounding-parity loop, the input-parsing cases and the admin client checks of section ۶) and shows
`PASS` / `FAIL` for each one.

Run it again after changing anything in `calc.js`.

---

## 7. How the money works (short version)

Per product: `base` (the price the shop sells it to the page) and `hp` (the page's profit per
unit), so `unit_sum = base + hp`. Version 2 has no cost and no shop profit any more — both
partners see exactly the same numbers.

| Field | Formula |
|-------|---------|
| `shipping_fee` | `post_fee` if shipping is `post`, else `0` |
| `sub` | `Σ q · unit_sum`, `net = sub − discount` |
| Cash total | `net + shipping_fee` |
| Snapp total | `roundToStep(net · snapp_multiplier, rounding_step) + shipping_fee` |
| Mixed: Snapp part `S` | entered by the seller, `0 < S < net`, integer ≥ 1 — **the exact amount the customer pays through Snapp Pay** (never multiplied) |
| Mixed: Snapp fee | `snapp_fee = max(0, snappRound(S) − S)` (exact integer math, §3 of the mixed-payment prompt); **the customer pays it in cash**. Tiny `S` with `snappRound(S) < S` clamps the fee to 0 with a non-blocking warning |
| Mixed: customer pays via Snapp | `snapp_charge = S` exactly |
| Mixed: customer pays cash | `cash_charge = (net − S) + snapp_fee + shipping_fee` |
| Mixed: customer total | `snapp_charge + cash_charge = net + shipping_fee + snapp_fee` |
| `payout` (Snapp settles) | `net + shipping_fee` (same as a cash sale) |
| Snapp deposit to the page | `0` (cash), `payout` (snapp), `S − snapp_fee` (mixed) |
| `owe` (page → shop) | `Σ q · base − shop_discount + shipping_fee` |
| `h_share` | `Σ q · hp − page_discount` |

Discount bearer: `helia` (پیج) → the page pays all of it, `mahdi` (مغازه) → the shop pays all of
it, `split` → half each. Invariants, for **every** method: `owe + h_share == payout`,
`snapp_charge + cash_charge == total`, `snapp_deposit + cash_charge == payout`, and for mixed
`snapp_charge == snapp_part`, `snapp_deposit == snapp_part − snapp_fee`, `total == payout + snapp_fee`.

Everything is recomputed **on the server** inside `create_order`; the client numbers are never trusted.

### Status flow

```
new ───────────────► paid ──► settled ──► shipped ──► delivered
awaiting_snapp ─────► paid       │
        └──────────► cancelled ◄─┘ (from new / awaiting_snapp / paid / settled)
```

- Cash orders start at `new` or `paid` (chosen when creating); Snapp and mixed (`ترکیبی`) orders start at `awaiting_snapp`.
- A **post** order can be marked `shipped` **without** a tracking code; the code may arrive days
  later and is then saved from the order card, from Accounts («ثبت کد») or from the ship dialog.
  Orders waiting for their code are marked «منتظر کد رهگیری».
- Cancelling removes the order from reports (shipped/delivered orders cannot be cancelled).

---

## 8. Screens

| Tab | What it does |
|-----|--------------|
| **محصولات** | Live prices (cash + Snapp), availability pill, search, «عدم موجودی» / «موجود شد» (shop only, existing orders untouched), products are archived, never deleted, CSV export. Shop edits name, «قیمت از مغازه» and «سود پیج», adds products and runs a bulk price update (% or fixed) on the shop price. Page edits only «سود پیج». **Admin** additionally sees «ویرایش کامل» (name, base price, hp, available, archived in one form) and «حذف کامل محصول» (typed-«حذف» confirm showing how many orders reference it; old orders keep their snapshots). |
| **سفارش جدید** | Product picker + quantities (an unavailable product blocks the save until it is removed), customer/phone/address/10-digit postal code, shipping, payment (cash / Snapp / mixed «ترکیبی» with a Snapp-part amount + ۲۵٪/۵۰٪/۷۵٪ helper chips), Snapp multiplier override, discount + bearer, live summary. For mixed the label reads «مبلغ اسنپ‌پی مشتری (تومان)»: what the customer pays via Snapp; the fee is shown inside the cash row («شامل کارمزد اسنپ‌پی») and «واریزی اسنپ‌پی به پیج» shows what Snapp settles. |
| **سفارش‌ها** | Pinned first then newest; search (name/phone/postal/product/tracking), filters (status, payment incl. «ترکیبی», shipping, pinned, «بدون کد رهگیری»), editable tracking code, status buttons (shipping works without a code), «ویرایش اطلاعات» for customer data only, «فاکتور در تلگرام من», pin + reason, CSV export (with `snapp_part`, `snapp_charge`, `cash_charge`, `snapp_fee`, `snapp_deposit`), and «ایمپورت لیست پست» (section 8.1). **Admin** additionally sees «ویرایش کامل» (full-screen modal: customer fields, all 7 statuses, tracking, shipping/payment with live summary, discount + bearer, the order's own settings snapshot, editable line list) and «حذف سفارش» (typed-«حذف» confirm; the card disappears, realtime removes it elsewhere). |
| **حساب‌ها** | «پول هنوز نرسیده» (`new`), «در انتظار تسویه اسنپ‌پی» (`awaiting_snapp`, sums and rows by Snapp deposit — `S` for mixed, `payout` for snapp — with a part breakdown on mixed rows), «بدهی پیج به مغازه» (`paid`), (shop only) «آماده ارسال» (`settled`) and «منتظر کد رهگیری»; per-row and bulk "mark as …" buttons, checkbox selection survives a live refresh, stale-money warning pills with a pin shortcut. |
| **گزارش‌ها** | Today / 7d / 30d / all / custom range: counts, sales, «سهم پیج», «پرداختی به مغازه», top-5 products, cash vs Snapp vs mixed counts with money split by channel (`cashSum = Σ cash_charge`, `snappSum = Σ snapp_charge`), post vs courier, discounts by bearer — the same for both partners. |
| **تنظیمات** | `post_fee`, `snapp_multiplier`, `rounding_step` (new orders only, each order snapshots the values it used), the «اعلان‌ها» card (Telegram link + phone notifications, plus the admin-only shared «حالت تست (بی‌صدا)» which drops the automatic partner/channel/push notifications while you try features — your own «اعلان آزمایشی» and invoice still work), **the admin-only «تاریخچه تغییرات ادمین» card** (latest 100 audit rows with a «بازگردانی» button on deletions), and the backup reminder. |

**Roles.** Version 2 has no secret numbers any more: both partners see `base`, `hp`, totals,
`owe` and `h_share`. What the database still enforces through **RLS** (not only the UI): only the
shop changes product names, `base_price`, availability and archives; only the page changes `hp`;
every money/status write goes through a `security definer` RPC; and a user without a `profiles`
row cannot read anything or call any RPC.

### 8.0 Admin powers («ادمین» only, enforced in the database)

Only the `admin` role (`public.is_admin()`) can edit or delete. Page and store users never see
the buttons, and calling the RPCs as them fails with «دسترسی غیرمجاز».

- **Orders:** «ویرایش کامل» edits customer data, shipping/payment/`S`, discount + bearer,
  tracking, any of the 7 statuses (bypassing the normal flow, logged as «تغییر توسط ادمین»),
  the three settings snapshots and the full line list (price snapshots per line, archived or
  unavailable products allowed). All money is recomputed server-side through `order_amounts`;
  the other partners get an `order_edited` notification. «حذف سفارش» is a **hard delete**
  (typed-«حذف» confirm): the only remaining copy is the audit row, which powers «بازگردانی».
- **Products:** «ویرایش کامل» changes name, base price, hp, available and archived in one call;
  «حذف کامل محصول» hard-deletes (typed-«حذف» confirm, shows how many orders reference it).
  Old orders keep their snapshots and stay readable.
- **Audit log:** every admin RPC writes one `audit_log` row in the same transaction (`before` /
  `after` snapshots). Settings → «تاریخچه تغییرات ادمین» lists the latest 100 with a short
  field diff; deletions offer «بازگردانی», which re-inserts the row with its original id
  (a second restore fails). Deletion is otherwise **permanent**.
- **Notifications:** `order_edited` («✏️ فاکتور … توسط ادمین ویرایش شد» + changed fields, max 6),
  `order_deleted` («🗑 سفارش … توسط ادمین حذف شد», channel post edited from the payload) and
  `product_deleted` («🗑 محصول … حذف شد»). Recipients: all linked partners except the actor;
  test mode («حالت تست») is respected. Push texts stay lock-screen safe (names only, no amounts).

### 8.1 Importing a post-office list («ایمپورت لیست پست»)

On the **سفارش‌ها** tab (both partners) the «ایمپورت لیست پست» button opens the import dialog.

1. Choose one or more post-office PDFs (the text layer is required — a photo/scanned PDF
   yields nothing). pdf.js is served from `lib/pdfjs/`, already in the repo.
2. Every row with a 24-digit barcode is read (recipient, city, weight) and matched to the
   post orders: green = clear winner (auto-selected), yellow = ambiguous (pick one of the
   top-5 candidates), red = no candidate (assign manually from the full list). Reversed
   visual order and the `لا/ال` letter swap are handled automatically.
3. Review the table: a row whose order already has a tracking code only overwrites it when
   its «جایگزین شود» toggle is on (default off); a barcode that already belongs to another
   order blocks that row. Optionally tick «همزمان وضعیت سفارش‌های "آماده ارسال" را
   "ارسال‌شده" کن».
4. «ثبت» writes the codes through `bulk_set_tracking` in 200-row chunks and shows how many
   were updated / skipped and why. Nothing is written before you press it.

Requires migration `004_bulk_set_tracking.sql` (section 12). No data ever leaves the browser.

---

## 9. Assumptions (decisions taken where the spec was open)

1. **Order lines are stored once** in `orders.items` as `{product_id, name, qty, base, hp}` — there is
   no separate private table any more, so both partners read exactly the same numbers.
2. **No `UPDATE`/`DELETE` policies on `orders`, `products`, `profiles`.**
   Every write goes through a `security definer` RPC, so validation and history stay atomic.
3. **Cancellation** is allowed only from `new`, `awaiting_snapp`, `paid`, `settled`.
   Shipped/delivered orders are terminal — pin the order to follow up instead (the error message says so).
4. **Classic scripts, not ES modules** (`<script src>` instead of `type="module"`) so `tests.html`
   also works when opened directly from disk (`file://`), where module imports are blocked by CORS.
5. **Accounts buckets**: «پول هنوز نرسیده» (`new`), «در انتظار تسویه اسنپ‌پی», «بدهی پیج به مغازه»,
   «آماده ارسال» (shop only, `settled`) and «منتظر کد رهگیری`; they are plain filters over `status`.
6. **Bulk price update** applies to `base_price`: percent → `round(base · (1 + v/100))`,
   fixed → `round(base + v)`; negative results clamp to `0`. The SQL RPC applies the same rounding.
7. **Report ranges are computed in the viewer's local timezone** (Today/7/30/custom are local dates).
8. **CSV export** contains *all* orders (cancelled included), UTF-8 with BOM for Excel, and is
   identical for both partners (no private columns).
9. **Accounts buttons**: «پول رسید» sets `paid` (from `new` or `awaiting_snapp`), «تسویه شد» sets
   `settled` (from `paid`), «ارسال» opens the ship dialog, «ثبت کد» saves a tracking code. Orders can
   be selected individually before a bulk action, and the selection survives a live refresh.
10. **Availability** is a blocker, not a warning: an unavailable product cannot be picked in a new
    order, and a line that goes unavailable while it is in the cart disables the save button until
    it is removed.
11. **Realtime + polling**: `orders`, `products` and `settings` are subscribed over Supabase Realtime
    (600 ms debounce) with a 45-second polling fallback; the service worker never caches API calls,
    so data is always network-first.
12. **Products are archived, never deleted**, so old orders keep valid product names.
13. **Pinning, status changes and tracking edits are allowed for both partners** (the spec restricts
    nothing here).
14. **Users are created manually** in the Supabase dashboard (admin + page; the store slot
    stays empty until needed) and their `profiles` row is inserted by
    hand — the app never signs people up.
15. **Mixed payment**: the Snapp part `S` is defined on the cash-equivalent goods value
    after discount and equals exactly what Snapp Pay deposits to the page account.
16. **Mixed payment**: shipping is always paid in the cash part and is never multiplied
    (consistent with pure Snapp orders).
17. **Mixed payment**: the cash part is treated as received at creation; mixed orders start
    as `awaiting_snapp` and only the Snapp part is outstanding (no per-part status tracking).
18. **Mixed payment**: `0 < S < net` is enforced, never clamped — if the cart or discount
    changes so that `S ≥ net`, the form blocks saving until `S` is fixed.
19. **Mixed payment**: `p_status` is ignored for mixed (forced `awaiting_snapp`), exactly
    like `snapp` today — which also ignores it rather than requiring null.
20. **Mixed payment**: a null discount bearer computes as `helia`, matching what the
    validator already accepts; the frontend never sends null.
21. **Mixed payment (follow-up)**: the Snapp part is the customer's exact Snapp charge;
    the fee is clamped to 0 (with a warning) when `snappRound(S) < S` for tiny parts.
22. **Admin edits** keep the order's own settings snapshot unless overridden; the one
    exception is switching a courier order to post with no `shipping_fee` override, which
    falls back to the current global `post_fee` (the courier row stores no post snapshot).
23. **Admin status override** bypasses the normal flow and is logged in `status_history`
    with the note «تغییر توسط ادمین»; payment-method changes keep the current status
    unless the admin passes one explicitly.
24. **Deleted channel posts** show the customer line plus «🗑 این سفارش حذف شد» (the full
    original text is unavailable — the row is gone — so only the customer line is kept).

## 9.1 Display names

Internal identifiers never change, but every string a user can read uses the new display names:

| Internal (never changes) | Displayed |
|---|---|
| role `helia` | **پیج** (page) |
| role `mahdi` | **مغازه** (shop) |
| role `admin` | **ادمین** (admin) |

They come from `UI.PARTY_LABEL` / `UI.partyLabel(role)` in `ui.js` (re-exported as `ROLE_LABEL` in
`app.js`), and `UI.BEARER_LABEL` for the discount bearer (`helia` → پیج, `mahdi` → مغازه,
`split` → نصف‌نصف). CSV headers use `owe_to_shop`, `page_share`, `shop_discount`, `page_discount`.
The words «مهدی» and «هلیا» never appear in UI text, toasts, confirmations, CSV headers or the
manifest.

---

## 10. Notifications (outbox + `notify`)

Every change to an order or a product is written to the `outbox` table **by the database**
(triggers created in `migrations/003_notifications.sql`), and the `notify` Edge Function wakes up,
claims a batch atomically (`claim_outbox`), and sends: a Telegram DM to the *other* partner, one
message per order in the private channel (created once, **edited** when the tracking code changes
or the order is cancelled), plus Web Push (see §9.5, phase 7).

### 10.0 Create the bot and the channel (once)

1. In Telegram talk to **@BotFather** → send `/newbot` → pick a name and a username → copy the
   token (`123456:ABC-…`). Treat it like a password.
2. Create a **private** channel for the two partners and add the bot as an **administrator**
   with the permission to post messages.
3. Get the channel id: post any message in the channel, then open
   `https://api.telegram.org/bot<TOKEN>/getUpdates` in a browser and read `chat.id`
   (it looks like `-1001234567890`). Reading Telegram from Iran needs a VPN; the Edge Functions
   run outside Iran and call Telegram without one.
4. Continue with 10.1 (migration) → 10.2 (secrets) → 10.3 (deploy).

### 10.1 Apply migration 003

Dashboard → **SQL Editor** → paste and run `migrations/003_notifications.sql`.
It is idempotent (safe to re-run). A fresh install already has all of this from `setup.sql`.

### 10.2 Secrets

Dashboard → **Edge Functions → Secrets** (or `supabase secrets set NAME=value`):

| Secret | Value |
|---|---|
| `TELEGRAM_BOT_TOKEN` | from @BotFather |
| `TELEGRAM_BOT_USERNAME` | the bot name without `@` |
| `TELEGRAM_CHANNEL_ID` | `-100…` (private channel) |
| `TELEGRAM_WEBHOOK_SECRET` | a random string you invent |
| `WEBHOOK_SECRET` | another random string you invent |
| `APP_URL` | your GitHub Pages URL, **without** a trailing slash |

### 10.3 Deploy `notify`

```bash
supabase functions deploy notify --no-verify-jwt
```

`--no-verify-jwt` is required: the database calls this function with a secret header
(`x-webhook-secret`) instead of a user token, and the function answers 401 to any other caller.
Dashboard alternative: **Edge Functions → notify → Deploy**.

### 10.4 Point the database at it

SQL Editor:

```sql
insert into app_private.config(key, value) values
  ('notify_url',     'https://<ref>.supabase.co/functions/v1/notify'),
  ('webhook_secret', '<the WEBHOOK_SECRET from 10.2>')
on conflict (key) do update set value = excluded.value;
```

Without this the database skips the wake-up call (you still see a notice in the SQL output) and
only the built-in cron wake-up (every 2 minutes) delivers.

### 10.5 Verify the tracking-added-later flow

1. As **پیج** create an order → the shop gets the invoice DM, the channel shows
   customer, Jalali date, `⏳ هنوز ثبت نشده` and `وضعیت: …` (no button on channel posts).
2. As **مغازه** mark it shipped **without** a code (confirm dialog) → the page is notified
   and the channel message edits its `وضعیت:` line (still no code).
3. Save the tracking code → within seconds the channel message shows `کد رهگیری` in `<code>`
   and the page gets «🚚 کد رهگیری سفارش …». This is an **edit** of the same message, never a
   second one.
4. Change the code → the message updates. Clear it → the `⏳` line returns.
5. Cancel the order → the channel message gains «❌ این سفارش لغو شد».

Telegram is filtered in Iran: reading the bot and the channel needs a VPN, but Edge Functions run
outside Iran and call Telegram normally. If Telegram is unreachable, orders still save — the
`outbox` rows keep `last_error` and are retried on the next wake-up.

### 10.6 Deploy the other functions and connect the accounts

```bash
supabase functions deploy telegram-webhook --no-verify-jwt   # Telegram calls this one
supabase functions deploy send-invoice                        # JWT verification stays ON
```

Then register the webhook once (browser or curl), so Telegram forwards `/start`, `/stop` and
`/help` to your function:

```
https://api.telegram.org/bot<TOKEN>/setWebhook?url=https://<ref>.supabase.co/functions/v1/telegram-webhook&secret_token=<TELEGRAM_WEBHOOK_SECRET>
```

**Connect an account:** open تنظیمات → «اعلان‌ها» → «اتصال تلگرام», a Telegram tab opens with a
link, press **Start** there, and the app shows «متصل است». «قطع اتصال» stops the DMs again
(inside Telegram `/stop` does the same). Fill `telegramBotUsername` in `app.js` first.

The invoice button on every order card («فاکتور در تلگرام من») sends the full invoice to your own
Telegram chat; without a link it asks you to connect first.

### 10.7 Web Push (notifications on the phone)

1. Generate the keys once (needs Node.js): `npx web-push generate-vapid-keys`.
2. The **public** key goes into `app.js` (`vapidPublicKey`). The **private** key, the subject
   (`VAPID_SUBJECT=mailto:you@example.com`), `TELEGRAM_BOT_TOKEN`, `TELEGRAM_BOT_USERNAME`,
   `TELEGRAM_CHANNEL_ID`, `TELEGRAM_WEBHOOK_SECRET`, `WEBHOOK_SECRET` and `APP_URL` go into
   **Edge Functions → Secrets** (`supabase secrets set NAME=value` works too).
3. Deploy the test function (JWT verification stays **ON**):
   `supabase functions deploy test-notify`.
4. Open تنظیمات → «اعلان‌ها» → «فعال‌سازی اعلان», then «ارسال اعلان آزمایشی».

Notes:
- **iOS:** pushes only reach the Home Screen app (Share → Add to Home Screen, then open it from
  there); the Settings screen says exactly that when the app is not installed yet.
- Without the VAPID keys `notify` simply skips the push and still sends the Telegram DMs, so the
  app works before you set this up.
- Every notification tap opens the app on the right screen and highlights the order (deep link
  `?view=orders&order=<id>`).

---

## 11. Troubleshooting

| Symptom | Fix |
|---------|-----|
| "ابتدا مقادیر Supabase را در ابتدای فایل app.js تنظیم کنید" | Fill `CONFIG` at the top of `app.js`. |
| "پروفایل شما در سیستم ثبت نشده است" | Insert the row into `profiles` (step 2.4). |
| "ایمیل یا رمز عبور اشتباه است" | Check the user exists under **Authentication → Users**. |
| Changes by the other partner do not appear | Wait ~1 s (debounce) or tap the refresh button; check Realtime is enabled. |
| Old orders changed after editing settings | They should not — each order stores its own `shipping_fee`, `snapp_multiplier`, `rounding_step`. Verify the RPC ran (`setup.sql` re-run). |
| Icons/manifest 404 on Pages | Make sure all files are in the deployed folder and paths stay relative. |
| No Telegram message after a new order | `notify` deployed with `--no-verify-jwt`? Secrets set? `select * from app_private.config;` must contain `notify_url` and `webhook_secret`. |
| A notification never arrives | `select id, kind, attempts, last_error, created_at from outbox order by id desc limit 10;` — after 5 attempts a row stops being retried, so fix the cause (`last_error`) and run `update outbox set attempts = 0 where id = <id>;`. |
| No phone notification | iOS needs the Home Screen install and permission (10.7); `select user_id, endpoint from push_subscriptions;` must contain your row, and the VAPID secrets must be set. |

---

## 12. Upgrading an existing database

1. **Back up first**: export the orders as CSV from the app («خروجی CSV» in سفارش‌ها). For a
   version-1 database also run `select * from product_costs;` and `select * from order_private;`
   in the SQL Editor and save the results — migration 002 drops both tables.
2. In the SQL Editor run, **in this order**, the idempotent migrations:
   `migrations/001_security.sql` →
   `migrations/002_simplify_products.sql` →
   `migrations/003_notifications.sql` →
   `migrations/004_bulk_set_tracking.sql` →
   `migrations/005_fix_bulk_set_tracking.sql` →
   `migrations/006_telegram_pause.sql` →
   `migrations/007_admin_role.sql` → `migrations/008_mixed_payment.sql` →
   `migrations/009_mixed_snapp_charge.sql` → `migrations/010_admin_edit_delete.sql`.
   Running one twice changes nothing.
   A fresh database needs none of them: `setup.sql` already contains everything.
   Migration 004 adds the `bulk_set_tracking` RPC (section 8.1); until it is applied the
   «ایمپورت لیست پست» button reports a missing-RPC error and changes nothing.
   Migration 006 adds the shared `telegram_paused` setting («حالت تست»); until it is
   applied the toggle reports an error and notifications behave as before (live).
   Migration 008 adds mixed payment; until it is applied, creating a mixed order fails
   server-side and the new `loadOrders` columns break the orders list — run it before
   pushing the frontend.
   Migration 009 fixes the mixed money model (Snapp part = real charge, new
   `snapp_fee`/`snapp_deposit` columns, backfills legacy mixed rows without touching
   totals) — run it before pushing the frontend, after exporting a CSV backup.
   Migration 010 adds the `audit_log` table and the `admin_*` RPCs; until it is applied
   the admin edit/delete buttons report a missing-RPC error and change nothing.
3. Supabase Dashboard → **Authentication → Providers → Email** → turn **OFF** «Allow new users to
   sign up» (the app has only its hand-created users, section 5.4 of the spec).
4. Set the secrets (10.2), deploy the four functions (10.3, 10.6, 10.7), register the Telegram
   webhook (10.6) and fill `app_private.config` (10.4).
5. Push the new frontend files — GitHub Pages republishes itself on every push.

---

## 13. Testing

**Automated**

| Where | What |
|-------|------|
| `tests.html` in a browser | Money examples, rounding regressions, number parsing, post-list import fixtures, mixed payment (OWNER/M1–M9, error cases, 5,000-combo sweep, parity loop, `snappDeposit`, input parsing, reports identity) and the admin client section ۶ (line-list totals, typed-«حذف» rule, snapshot override). |
| `deno test supabase/functions/_shared/format.test.ts` | 9 checks: Jalali date, channel text, invoice (mixed lines with fee), merge rule, push payload, and the three admin events (`order_edited`, `order_deleted` + deleted channel text, `product_deleted`). |
| `tests/mixed_payment.sql` in the SQL Editor | OWNER/M1–M9, all error cases, all 13 old examples and a 500-combo invariant sweep against `public.order_amounts` (no login needed; ends with `ALL PASSED`). |
| `tests/admin_edit_delete.sql` in the SQL Editor | Admin RPCs on throw-away rows (rolled back): non-admin block on all 7 RPCs, delivered-order edit (2 cases + invariants), cash → mixed OWNER numbers, unknown-key rejection, delete (audit + `order_deleted` + pending processed), restore (same id, double-restore fails), product delete count + snapshots. Ends with `ALL PASSED`. |
| SQL harness (`run.js`) | 329 checks: both installation paths, all grants and RLS, the money invariants and the notification RPCs (development only, not shipped). |

**Manual checklist — run once after every deploy**

1. Log in as the shop: chip says «مغازه»; as the page: «پیج»; no old names anywhere.
2. Add a product (shop price 500,000, page profit 150,000): cash + post total 840,000, owed to
   the shop 690,000, page share 150,000; Snapp + post 940,000; a 350,000 unit with Snapp + post
   is 595,000 in the form and in the stored order.
3. Discount 50,000 with each bearer gives owe 690,000 / 640,000 / 665,000 and page share
   100,000 / 150,000 / 125,000.
4. Shop taps «عدم موجودی» on a product: it dims, cannot be added to a new order, the server
   rejects it too, and the page gets a push/DM. Tap «موجود شد»: back to normal. The page account
   sees no toggle. Existing orders are unaffected.
5. Settings: set post fee to 0, save, reload: it stays 0; set Snapp multiplier 1.2: new Snapp
   orders use it, old ones unchanged.
6. Page creates an order: the shop gets the full invoice DM; the channel gets
   customer, Jalali date, «⏳ هنوز ثبت نشده» and the status line (no «باز کردن در اپ» button there).
7. Shop marks it shipped without a code (confirm dialog): the page is notified; the order shows
   «منتظر کد رهگیری» with day count and appears in the Accounts bucket.
8. Force the daily reminder (`select public.queue_tracking_missing();` in the SQL Editor): both
   partners get one reminder.
9. Shop saves the code: within seconds the channel message shows the code and the page gets
   «کد رهگیری سفارش …». Change the code: the message updates; clear it: the «⏳» line returns.
10. Cancel an order: the channel message shows the cancelled line; the other partner is notified;
    reports exclude it.
11. iPhone: install to the Home Screen, enable notifications in Settings, use the test button,
    then create an order from the other phone: a push arrives and tapping it opens that order and
    highlights it.
12. Break the Telegram token temporarily: orders still save; failed outbox rows keep `last_error`;
    after fixing, the next wake-up delivers them.
13. An outsider cannot sign up, and a user without a profile cannot read data or call RPCs.
14. Old orders created before the migration still display correctly.
15. Test mode: in Settings → «اعلان‌ها» tap «شروع تست (بی‌صدا)», create an order from the
    other phone — the partner gets no DM, push or channel message; your own «ارسال اعلان
    آزمایشی» and «فاکتور در تلگرام من» still work. Tap «پایان تست» afterwards.
16. Mixed payment: new order → «ترکیبی», Snapp part 325,000 on a 650,000 courier order:
    summary shows «پرداخت با اسنپ‌پی (مشتری)» 325,000 + «پرداخت نقدی (مشتری)» 375,000
    («شامل کارمزد اسنپ‌پی: 50,000») = total 700,000; «واریزی اسنپ‌پی به پیج» 275,000;
    the confirm dialog names both parts; the stored card shows the part cells; Accounts
    «در انتظار تسویه اسنپ‌پی» counts 275,000; the invoice DM (فاکتور در تلگرام من) lists
    both parts with the fee and the settlement.
17. Admin edit: log in as ادمین — order cards show «ویرایش کامل» and «حذف سفارش»,
    product cards show «ویرایش کامل» and «حذف کامل محصول»; log in as پیج/مغازه — none
    of them are visible. As admin open «ویرایش کامل» on a delivered order: the banner shows,
    change items/prices and switch cash → mixed (OWNER numbers appear in the live summary),
    save — totals recompute, the other partner gets «✏️ فاکتور … ویرایش شد», the channel
    post edits when customer/status/tracking changed.
18. Admin delete/restore: as admin delete an order (type «حذف» to enable): toast
    «سفارش حذف شد», the card disappears, the partner gets «🗑 سفارش … حذف شد» and the
    channel post gains «🗑 این سفارش حذف شد». Settings → «تاریخچه تغییرات ادمین» →
    «نمایش تاریخچه» lists the delete; «بازگردانی» brings it back with the same id.
    Open a deleted order's deep link (`?view=orders&order=<id>`): no crash, no highlight.
19. Admin product delete: the confirm shows how many orders reference the product; after
    deletion those orders still render with their old snapshots.
