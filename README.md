# Delsana Management

A small, production-ready PWA for the Delsana cosmetics business (Mahdi's wholesale shop + Helia's Instagram store).
Plain HTML/CSS/vanilla JavaScript, no framework, no build step, no `npm`. Backend is **Supabase** (Postgres + RLS + Realtime).

- Persian UI, RTL, light/dark theme, mobile-first (works on phone and desktop).
- Two accounts only: `mahdi` (full access) and `helia` (own profit only).
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
| `screens.js` | The six screens (products, new order, orders, accounts, reports, settings) |
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
3. This creates: `profiles`, `products`, `product_costs`, `orders`, `order_private`, `settings`,
   the `base_price` trigger, all RLS policies, the indexes, and every RPC
   (`create_order`, `set_order_status`, `cancel_order`, `bulk_set_status`, `set_tracking`,
   `set_pin`, `add_product`, `update_product`, `set_hp`, `set_cost`, `bulk_cost_update`).

### 2.3 Create the two users
1. Dashboard → **Authentication → Users → Add user**.
   - e.g. `mahdi@example.com` + a strong password → **Create user** (no need to confirm the email).
   - e.g. `helia@example.com` + a strong password → **Create user**.
2. **There is no sign-up screen on purpose.** The app has exactly two users.

### 2.4 Give each user a role (required!)
The app reads the role from `profiles`. Run this in the SQL Editor with the real `user_id`
values from **Authentication → Users** (the UUID column):

```sql
insert into public.profiles (user_id, role) values
  ('<mahdi-user-uuid>', 'mahdi'),
  ('<helia-user-uuid>', 'helia')
on conflict (user_id) do update set role = excluded.role;
```

Without this row the user can log in but will see: *"your profile is not registered"*.

### 2.5 Realtime
`setup.sql` already adds `orders`, `products` and `settings` to the `supabase_realtime` publication.
If your project disabled Realtime, enable it under **Database → Replication**.

---

## 3. Configure the frontend

Open `app.js` and fill the two values at the very top:

```js
const CONFIG = {
  supabaseUrl: 'https://abcdefgh.supabase.co',      // Dashboard -> Project Settings -> API
  supabaseAnonKey: 'eyJ...'                          // the "anon public" key only
};
```

Rules:
- **Never** put the `service_role` key in the frontend. Only the anon key.
- The app refuses to start (and shows a Persian message) while these still read `YOUR_…`.

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

Open `tests.html` in a browser. It runs all **10 worked examples** from the specification plus the
invariant `owe_to_mahdi + helia_share == payout` for each one, and shows `PASS` / `FAIL`.

Run it again after changing anything in `calc.js`.

---

## 7. How the money works (short version)

Per product: `base = cost + mp`, `unit_sum = cost + mp + hp`.

| Field | Formula |
|-------|---------|
| `shipping_fee` | `post_fee` if shipping is `post`, else `0` |
| `sub` | `Σ q · unit_sum`, `net = sub − discount` |
| Cash total | `net + shipping_fee` |
| Snapp total | `roundToStep(net · snapp_multiplier, rounding_step) + shipping_fee` |
| `payout` (Snapp settles) | `net + shipping_fee` (same as a cash sale) |
| `owe` (Helia → Mahdi) | `Σ q · base − mahdi_discount + shipping_fee` |
| `h_share` | `Σ q · hp − helia_discount` |
| `m_profit` | `Σ q · mp − mahdi_discount` |

Discount bearer: `helia` → all on Helia, `mahdi` → all on Mahdi, `split` → `floor(D/2)` on Mahdi.

Everything is recomputed **on the server** inside `create_order`; the client numbers are never trusted.

### Status flow

```
new ───────────────► paid ──► settled ──► shipped ──► delivered
awaiting_snapp ─────► paid       │
        └──────────► cancelled ◄─┘ (from new / awaiting_snapp / paid / settled)
```

- Cash orders start at `new` or `paid` (chosen when creating); Snapp orders start at `awaiting_snapp`.
- A **post** order can be marked `shipped` **without** a tracking code; the code may arrive days
  later and is then saved from the order card, from Accounts («ثبت کد») or from the ship dialog.
  Orders waiting for their code are marked «منتظر کد رهگیری».
- Cancelling removes the order from reports (shipped/delivered orders cannot be cancelled).

---

## 8. Screens

| Tab | What it does |
|-----|--------------|
| **محصولات** | Live prices (cash + Snapp), search, low-stock highlight. Mahdi edits name/stock/cost/mp, adds and archives products, bulk price update (% or fixed). Helia edits only her profit. |
| **سفارش جدید** | Product picker + quantities, customer/phone/address/10-digit postal code, shipping, payment, Snapp multiplier override, discount + bearer, live summary, over-stock warning (does not block). |
| **سفارش‌ها** | Pinned first then newest; search (name/phone/postal/product/tracking), filters (status, payment, shipping, pinned, «بدون کد رهگیری»), editable tracking code, status buttons (shipping works without a code), «ویرایش اطلاعات» for customer data only, pin + reason, CSV export. |
| **حساب‌ها** | «پول هنوز نرسیده» (`new`), «در انتظار تسویه اسنپ‌پی» (`awaiting_snapp`), «بدهی پیج به مغازه» (`paid`), (shop only) «آماده ارسال» (`settled`) and «منتظر کد رهگیری»; per-row and bulk "mark as …" buttons, checkbox selection survives a live refresh, stale-money warning pills with a pin shortcut. |
| **گزارش‌ها** | Today / 7d / 30d / all / custom range: counts, sales, Helia's profit, top-5 products, cash vs Snapp, post vs courier, discounts by bearer. Mahdi's profit only on Mahdi's account. |
| **تنظیمات** | `post_fee`, `snapp_multiplier`, `rounding_step`. Applies to new orders only (each order snapshots the values it used). |

**Roles.** Mahdi sees cost, his profit and his profit totals. Helia sees "price from Mahdi" (`base`) and her own profit — never `product_costs` or `order_private`. This is enforced by **RLS in the database**, not only in the UI: Helia's session cannot read those tables, and all money/status writes go through `security definer` RPCs.

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
14. **Users are created manually** in the Supabase dashboard and their `profiles` row is inserted by
    hand — the app never signs people up.

## 9.1 Display names

Internal identifiers never change, but every string a user can read uses the new display names:

| Internal (never changes) | Displayed |
|---|---|
| role `helia` | **پیج** (page) |
| role `mahdi` | **مغازه** (shop) |

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
   «📦 سفارش جدید» with `⏳ هنوز ثبت نشده`.
2. As **مغازه** mark it shipped **without** a code (confirm dialog) → the page is notified.
   The channel message does not change (there is still no code).
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
