# MASTER PROMPT: "Delsana Management" v2 (one file, all changes)

You are a senior engineer working on an existing, deployed app (repo `delsana-manage`): vanilla HTML/CSS/JS frontend (`index.html`, `style.css`, `app.js`, `db.js`, `calc.js`, `ui.js`, `screens.js`, `sw.js`, `manifest.json`, `tests.html`) and a Supabase backend (`setup.sql`). Two partners use it, both on iPhone as an installed Home Screen web app, hosted on GitHub Pages.

Do NOT ask me questions. If something is ambiguous, choose the most sensible option, write the assumption in `README.md`, and continue. Implement everything in this file, in the phases of section 13. Verify every phase. At the end write `CHANGELOG.md` (English) listing every numbered item of this file and whether it is done.

---

## 0. HARD RULES

1. All user-facing text is Persian. Code, comments, README and CHANGELOG are English.
2. Keep these internal identifiers unchanged (they are not display names): profile roles `'mahdi'` and `'helia'`, `orders.discount_bearer` values `'helia'|'mahdi'|'split'`, `isMahdi`, `mahdi_discount`, `helia_discount`, `h_share`, `owe`, status keys, existing RPC names that are not listed as renamed in section 3, element ids and CSS classes, localStorage keys.
3. Display names: role `helia` is shown as **«پیج»** and role `mahdi` is shown as **«مغازه»** everywhere users can read text (app UI, Telegram messages, push text, CSV headers, README). Never write «مهدی» or «هلیا» in user-visible text. See section 4.
4. Secrets (Telegram bot token, webhook secrets, VAPID private key, service role key) live only in Supabase secrets/config. The repository is public: never commit secrets. Only the VAPID PUBLIC key and the Supabase anon key may be in frontend code.
5. After each phase open `tests.html`; every check must PASS.
6. Old orders must remain intact and readable (they store snapshots of `items`, `owe`, `h_share`, etc.).
7. Notifications must never block or break the main flow (use the outbox, section 9).

---

## 1. BUSINESS CONTEXT (updated)

- The SHOP (role `mahdi`) sells goods to the PAGE (role `helia`) at a fixed shop price per product.
- The PAGE (an Instagram seller) adds her own profit per product and sells to customers. The customer's money arrives in the page's bank account (immediately for cash/card, later for Snapp Pay). The page keeps her profit and transfers the rest to the shop: (shop prices of the goods, minus any discount the shop bears) + post shipping fee. After receiving the money, the shop ships the goods (post with a tracking code, or local courier).
- **Change in v2:** the app no longer tracks the shop's purchase cost, the shop's own profit, or stock quantities. A product has only: `base_price` (the price the shop sells it to the page), `hp` (the page's profit per unit), and an `available` flag.
- Both partners can see all remaining numbers. There is no secret data between them anymore, so role-based hiding/redaction of cost or shop profit is removed.

Roles and permissions:
- Shop account (`mahdi`): edits product name, `base_price`, availability, archive; can add products; bulk price update; settings; everything the page can do on orders.
- Page account (`helia`): edits `hp` only; creates orders; changes order statuses, tracking, pin; settings.
- Enforce in the database (RLS + RPC role checks), not only in the UI.
- Public sign-up must be disabled in Supabase (section 5.4).

---

## 2. MONEY RULES v2 (currency: toman, integers; only the Snapp multiplier is non-integer and its result is rounded)

Per product: `base` (shop price per unit), `hp` (page profit per unit). `unit_sum = base + hp`.

Per order inputs: items with quantity `q`; discount `D >= 0`; `discount_bearer` in `helia | mahdi | split`; `shipping_method` in `post | courier`; payment `cash | snapp`; `snapp_multiplier` (default from settings, optional override per Snapp order).

Settings (stored in DB, editable in Settings by both partners): `post_fee` (default 190000, 0 allowed), `snapp_multiplier` (default 1.15), `rounding_step` (default 5000). Each order stores a snapshot of `shipping_fee`, `snapp_multiplier`, `rounding_step`.

Calculations (shared by `calc.js` and the SQL `create_order`, they must match exactly):

- `shipping_fee = (shipping_method == 'post') ? post_fee : 0`
- `sub = sum(q * unit_sum)`; `net = sub - D` (reject if `D > sub`)
- Discount split: bearer `helia`: `helia_discount = D`, `mahdi_discount = 0`; bearer `mahdi`: `mahdi_discount = D`, `helia_discount = 0`; bearer `split`: `mahdi_discount = floor(D / 2)`, `helia_discount = D - mahdi_discount`.
- CASH total for the customer = `net + shipping_fee`
- SNAPP total for the customer = `roundToStep(net * snapp_multiplier) + shipping_fee`. Snapp Pay deposits to the page the same amount as a cash sale: `payout = net + shipping_fee`. The fee and the rounding difference belong to nobody.
- `goods_owe = sum(q * base) - mahdi_discount` (must be >= 0; if negative reject with «تخفیف بر عهده مغازه از مبلغ کالاهای مغازه بیشتر است»)
- `owe = goods_owe + shipping_fee` (what the page transfers to the shop)
- `h_share = sum(q * hp) - helia_discount` (what the page keeps; show a non-blocking warning if negative)
- Invariant (assert in code and tests): `owe + h_share == net + shipping_fee`.
- REMOVED from v2: cost, shop profit (`mp`, `m_profit`, `cost_total`), `order_private`, `negative_mahdi_profit`.

`roundToStep` must be float-safe (fixes a verified browser/server mismatch):

```js
function roundToStep(x, step) {
  if (!isFinite(x)) throw new Error('roundToStep: not a number');
  var s = Math.floor(Math.abs(step)) > 0 ? Math.floor(Math.abs(step)) : 1;
  return Math.round(x / s + 1e-9) * s;   // epsilon removes float noise at exact .5 boundaries
}
```

SQL uses exact `numeric` math: `round(net * mult / step) * step` (Postgres rounds half away from zero, equal to the JS result for positive numbers).

`Calc.calcOrder` input item shape becomes `{ qty, base, hp }`; output keys: `sub, net, shipping_fee, customer_total, payout, owe, h_share, mahdi_discount, helia_discount, negative_helia_share, invariant_ok`.

Worked examples (unit tests in `tests.html`; product: qty 1, `base` 500,000, `hp` 150,000, `unit_sum` 650,000, `post_fee` 190,000, `rounding_step` 5000):

1. Cash, post, no discount: total 840,000; owe 690,000; h_share 150,000.
2. Cash, courier: total 650,000; owe 500,000; h_share 150,000.
3. Snapp 1.15, post: 747,500 rounds to 750,000; total 940,000; payout 840,000; owe 690,000; h_share 150,000.
4. Snapp 1.15, courier: total 750,000; payout 650,000; owe 500,000.
5. Snapp 1.2, post: 780,000; total 970,000; payout 840,000.
6. Cash, post, discount 50,000, bearer `helia`: total 790,000; owe 690,000; h_share 100,000.
7. Same, bearer `mahdi`: total 790,000; owe 640,000; h_share 150,000.
8. Same, bearer `split`: total 790,000; owe 665,000; h_share 125,000.
9. Cash, post, discount 50,001, bearer `split`: mahdi_discount 25,000; helia_discount 25,001; owe 665,000; h_share 124,999.
10. Snapp 1.15, post, discount 50,000, bearer `helia`: net 600,000; 690,000 + 190,000 = total 880,000; payout 790,000.
11. Rounding regression: a product with `base` 200,000 and `hp` 150,000 (unit 350,000), Snapp 1.15, post: total 595,000 (not 590,000/600,000 from float error). A product with `base` 30,000, `hp` 20,000 (unit 50,000), Snapp 1.15, courier: total 60,000.
12. Regression loop: for net = 1000..3,000,000 step 1000 with multiplier 1.15 and step 5000, `Calc.roundToStep(net * 1.15, 5000)` equals exact integer math `Math.floor((2 * net * 23 + 100000) / 200000) * 5000`.
13. Error: `base` 100,000, `hp` 400,000, discount 150,000, bearer `mahdi` is rejected (goods_owe < 0).
Plus the invariant check for every case.

---

## 3. PRODUCT MODEL CHANGE (no cost, no stock, availability toggle)

### 3.1 What is removed

- Tables: `product_costs` and `order_private` (and the trigger that computed `products.base_price` from costs).
- Column `products.stock`. Stock decrement on order creation and stock restore on cancel are removed everywhere (SQL and JS). The «موجودی کم» highlight, low-stock events and stock-related warnings are removed.
- JS: `App.costs`, cost/mp inputs, `DB.setCost`, `DB.bulkCostUpdate`, shop profit displays (order summary, order card, reports, CSV `cost_total`/`mahdi_profit`).
- RPCs `set_cost`, `bulk_cost_update` (replaced below).

### 3.2 New product columns and RPCs

`products(id, name, base_price bigint not null default 0, hp bigint not null default 0, available boolean not null default true, archived boolean not null default false, created_at)`.

RPCs (`security definer`, `set search_path = public`, `revoke ... from public, anon`, `grant execute ... to authenticated`):

- `add_product(p_name text, p_base_price bigint, p_hp bigint, p_available boolean default true)` — shop only (`is_mahdi()`).
- `update_product(p_id uuid, p_name text, p_archived boolean)` — shop only.
- `set_base_price(p_id uuid, p_price bigint)` — shop only; price >= 0.
- `bulk_price_update(p_ids uuid[], p_mode text, p_value numeric)` — shop only; mode `percent` (`new = round(old * (1 + value/100))`) or `fixed` (`new = old + value`); result clamped to >= 0; returns the number of updated rows. Negative values allowed.
- `set_hp(p_id uuid, p_hp bigint)` — any member; >= 0.
- `set_availability(p_id uuid, p_available boolean)` — shop only. Changing availability never touches existing orders.
- Every function requires `public.is_member()` (or `is_mahdi()` where stated).

`create_order(...)`: keep the existing parameters (items array of `{product_id, qty}`, customer, phone, address, postal_code, shipping_method, method, discount, discount_bearer, snapp_multiplier, note, status) and its server-side recomputation, with these changes:
- read `base_price` and `hp` from `products`; reject archived products and products with `available = false` («محصول «X» ناموجود است»);
- compute `owe`, `h_share`, `total`, `payout`, discounts per section 2 and store the item snapshots `{product_id, name, qty, base, hp}` in `orders.items`;
- no stock handling, no `order_private` insert;
- keep it atomic; set `last_actor = auth.uid()`.
`cancel_order`: only marks cancelled (no stock restore).

### 3.3 Frontend behavior

- Products screen cards show: name, availability pill, «قیمت نقدی» (`base + hp`), «قیمت اسنپ‌پی» (rounded, excluding shipping), «قیمت از مغازه» (`base`), «سود پیج» (`hp`).
- Shop account edit fields: name, «قیمت از مغازه (تومان)» and a **toggle button on every product card**: when available, a red-outlined button «عدم موجودی»; when unavailable, a button «موجود شد». One tap toggles (confirm dialog only when marking unavailable: «این محصول ناموجود شود؟ در سفارش جدید قابل انتخاب نخواهد بود.»). Page account sees the pill read-only, no toggle.
- Page account edit field: «سود پیج (هر واحد)».
- Unavailable cards are visually dimmed with a pill «ناموجود». Sort: available first (name order), then unavailable, then archived.
- Filter chips on the products screen: «همه» and «ناموجود» (count shown).
- Add product dialog (shop): name, «قیمت از مغازه», «سود پیج», checkbox «موجود است» (default checked).
- Bulk price update (shop) now applies to `base_price` (button text «اعمال روی قیمت مغازه») and the confirmation dialog previews the first 3 affected products with old and new price (computed client-side with the same rounding as the RPC).
- New order picker: unavailable products stay listed but disabled with the pill «ناموجود» and cannot be added. If a product in the cart becomes unavailable (realtime update), mark that line with a danger style «ناموجود شد» and disable the save button until it is removed. Remove all over-stock warnings.
- `priceInfo(p)` becomes `{ base: p.base_price, hp: p.hp, unit_sum: base + hp }` with no role-specific branches.
- Order summary rows (new order form): مبلغ کالاها، تخفیف (with bearer), هزینه ارسال، مبلغ قابل پرداخت مشتری، پرداختی به مغازه، سهم پیج، (Snapp) تسویه اسنپ‌پی. No shop profit row.
- Order card money cells: مبلغ مشتری، به مغازه، سهم پیج، تخفیف، تسویه اسنپ‌پی، هزینه پست. No shop profit cell.
- Reports (both partners see everything): KPI cards «تعداد سفارش»، «فروش کل»، «سهم پیج» (sum of `h_share`)، «پرداختی به مغازه» (sum of `owe`); remove the shop-profit KPI; keep cash vs Snapp split, post vs courier count, top 5 products by quantity, discount breakdown (section 5.8).
- CSV: remove `cost_total` and `mahdi_profit` columns.

### 3.4 Data migration for the existing database (`migrations/002_simplify_products.sql`)

Idempotent, with a header comment: "BEFORE running: export all orders as CSV from the app and run `select * from product_costs;` and `select * from order_private;` and save the results; they will be deleted."

Steps:
1. `alter table products add column if not exists available boolean not null default true;` (all existing products become available; the shop adjusts afterwards).
2. Keep `products.base_price` exactly as it is (it already equals the old `cost + mp`), set `not null default 0`.
3. Drop the trigger and function that synced `base_price` from `product_costs`.
4. `drop table if exists public.order_private cascade;` and `drop table if exists public.product_costs cascade;`.
5. `alter table products drop column if exists stock;`
6. Drop old functions `set_cost`, `bulk_cost_update`, the old `update_product`, `add_product`, and recreate all RPCs from 3.2 (plus the new `create_order`/`cancel_order` bodies).
7. Re-create RLS policies for `products` (select for members; no direct writes).
Fresh installs use `setup.sql`, which must be equal to "all migrations applied".

---

## 4. DISPLAY-NAME CHANGE: «پیج» and «مغازه» (display only)

| Internal identity (never changes) | Old display | NEW display |
|---|---|---|
| role `helia` | هلیا | **پیج** |
| role `mahdi` | مهدی | **مغازه** |

Implementation:
1. In `ui.js` add `var PARTY_LABEL = { mahdi: 'مغازه', helia: 'پیج' }; function partyLabel(role)`, exported as `UI.PARTY_LABEL` and `UI.partyLabel`.
2. `BEARER_LABEL` becomes `{ helia: 'پیج', mahdi: 'مغازه', split: 'نصف‌نصف' }`.
3. `app.js` `ROLE_LABEL` uses the same labels; the top-bar chip shows «مغازه» or «پیج».
4. Replace every visible string (search all `*.js`, `*.html`, `*.md`, and `tests.html`):

| Old | New |
|---|---|
| قیمت از مهدی | قیمت از مغازه |
| سود هلیا / سود هلیا (هر واحد) | سود پیج / سود پیج (هر واحد) |
| پرداختی به مهدی / به مهدی | پرداختی به مغازه / به مغازه |
| سهم هلیا | سهم پیج |
| سود هلیا منفی می‌شود؛ تخفیف را کم کنید | سود پیج منفی می‌شود؛ تخفیف را کم کنید |
| بدهی هلیا به مهدی | بدهی پیج به مغازه |
| تسویه با مهدی (`UI.ACTION_LABEL.settled`) | تسویه با مغازه |
| بر عهده مهدی / بر عهده هلیا | بر عهده مغازه / بر عهده پیج |
| login brand line «فروشگاه مهدی & اینستاگرام هلیا» | مغازه و پیج اینستاگرام |

Also check toasts, confirms, hints, placeholders, `aria-label`, `title`, empty states, the About card, README, CSV headers.
5. CSV header names: `owe_to_shop`, `page_share`, `shop_discount`, `page_discount`; write `discount_bearer` with `UI.bearerLabel`.
6. `README.md`: a short "Display names" section.
7. Acceptance: searching the code for `مهدی` and `هلیا` finds nothing user-visible (only comments/CHANGELOG), and all tests pass.

---

## 5. BUGS FOUND IN THE CODE REVIEW (fix all)

### 5.1 Snapp rounding mismatch browser vs server (HIGH)
Fix `roundToStep` as in section 2 and add the regression tests 11 and 12 there. (A verified example: net 350,000 gave 400,000 in the browser but 405,000 on the server.) Do not change the SQL rounding.

### 5.2 Saving settings fails (HIGH)
`DB.saveSettings` uses `upsert`, which needs an INSERT policy that `settings` does not have. Replace with updates:

```js
DB.saveSettings = async function (s) {
  var rows = [
    { key: 'post_fee', value: String(Math.trunc(Number(s.post_fee))) },
    { key: 'snapp_multiplier', value: String(Number(s.snapp_multiplier)) },
    { key: 'rounding_step', value: String(Math.trunc(Number(s.rounding_step))) }
  ];
  for (var i = 0; i < rows.length; i++) {
    await unwrap(App.supabase.from('settings').update({ value: rows[i].value }).eq('key', rows[i].key));
  }
  await DB.loadSettings();
  return App.settings;
};
```

### 5.3 Post fee 0 ignored (MEDIUM)
`DB.loadSettings` uses `Number(...) || DEFAULT`. Use an explicit validity check (`v` null/empty/non-finite means default; `0` is a valid `post_fee`). `snapp_multiplier` and `rounding_step` must be > 0 else default.

### 5.4 Public sign-up exposes all data (HIGH, security)
The Supabase URL and anon key are public. RLS must check membership, not just `authenticated`. In `setup.sql` and `migrations/001_security.sql` (idempotent):

```sql
create or replace function public.is_member() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where user_id = auth.uid());
$$;

drop policy if exists products_select on public.products;
create policy products_select on public.products for select to authenticated using (public.is_member());
drop policy if exists orders_select on public.orders;
create policy orders_select on public.orders for select to authenticated using (public.is_member());
drop policy if exists settings_select on public.settings;
create policy settings_select on public.settings for select to authenticated using (public.is_member());
drop policy if exists settings_update on public.settings;
create policy settings_update on public.settings for update to authenticated
  using (public.is_member())
  with check (public.is_member() and (
    (key = 'snapp_multiplier' and value ~ '^[0-9]+(\.[0-9]+)?$') or
    (key in ('post_fee','rounding_step') and value ~ '^[0-9]+$')));
```

In `set_hp`, `set_order_status`, `cancel_order`, `bulk_set_status`, `set_tracking`, `set_pin` replace `auth.uid() is null` checks with `not public.is_member()` and raise «دسترسی غیرمجاز». Add `is_member()` to the REVOKE/GRANT block. README and the final report must say: turn OFF "Allow new users to sign up" in Supabase (Authentication, Sign In / Providers).

### 5.5 Settings values not validated (MEDIUM)
Covered by the policy above. In `create_order` read settings defensively: if a value is not numeric raise «تنظیمات نامعتبر است».

### 5.6 Tracking code optional for `shipped` (behavior change)
See section 6. Remove any rule requiring a tracking code to mark `shipped`.

### 5.7 Courier name not saved (MEDIUM)
In `screens.js` `changeStatus`, handle `shipped` for both methods: read the order card's tracking input value; for post with an empty value show the confirm of section 6; save with `DB.setStatus(o.id, 'shipped', val || null, null)` then reload and `repaintOrders()`.

### 5.8 Discount report wrong (MEDIUM)
The row «بر عهده نصف‌نصف» is always 0 (`dTotal - dMahdi - dHelia`). Replace with totals by chosen bearer:

```js
var dBy = { helia: 0, mahdi: 0, split: 0 };
rows.forEach(function (o) { dBy[o.discount_bearer] = (dBy[o.discount_bearer] || 0) + Number(o.discount || 0); });
```
Rows: جمع کل تخفیف؛ تخفیف‌های بر عهده پیج؛ بر عهده مغازه؛ نصف‌نصف.

### 5.9 «New» orders invisible in Accounts (MEDIUM)
Add a bucket «پول هنوز نرسیده» for status `new` (row button «پول رسید» sets `paid`; bulk button via `bulk_set_status` extended to accept target `paid` from `new` and `awaiting_snapp`).

### 5.10 Ship dialog should prefill the saved tracking code (LOW)
Pass `value: o.tracking || ''` to `UI.prompt`.

### 5.11 Accounts checkboxes reset on live refresh (LOW)
Store selections in a module-level object keyed by `kind:orderId`; restore on render; select-all updates it.

### 5.12 Typo (LOW)
Settings hint «× این ضیب» becomes «× این ضریب».

### 5.13 Stale multiplier placeholder (LOW)
Update `#no-mult` placeholder from `App.settings.snapp_multiplier` in `neworder.refresh()`.

### 5.14 Number parsing (MEDIUM)
In `ui.js`: `parseFloat10` converts `−` (U+2212), `–` (U+2013), `—` (U+2014) to `-` and treats a trailing minus (`5000-`, `۵۰۰۰−`) as a leading minus (otherwise a price reduction becomes an increase). `parseInt10` drops any fractional part (`1.5` or `1٫5` gives `1`, not `15`). Add tests: `"۵۰۰۰−"` gives -5000; `"1,500"` gives 1500; `"1.5"` gives 1.

### 5.15 Silent failure in grants (LOW)
Remove `exception when others then null` from the final grant block of `setup.sql` (or `raise warning` with `SQLERRM`).

### 5.16 Minor
- `app.js` `switchView`: `'instant' in window` is always false; use `behavior: 'auto'`.
- Remove `.idea/` and the stray `delsana-prompt.md` from the repo; add `.gitignore` (`.idea/`, `.DS_Store`, `node_modules/`).
- `sw.js`: review it. It must never cache Supabase API or Edge Function requests, must be cache-first only for same-origin static files, and its cache name must include a version that you bump now (for example `delsana-v3`).
- Fix grammar of «بدهی بازی وجود ندارد» to «بدهی بازی ندارید».

---

## 6. TRACKING CODE MAY ARRIVE DAYS AFTER SHIPPING

The post tracking code is sometimes available only days after the goods were handed to the post. Therefore:

- `set_order_status` allows `shipped` with an empty tracking code, for post and courier orders alike.
- `set_tracking` works for any non-cancelled order (in particular `shipped` ones) and may clear a code; it sets `last_actor`.
- UI: when marking a post order as shipped with an empty tracking input, show a confirm dialog «کد رهگیری هنوز ثبت نشده است. سفارش بدون کد ارسال شود و کد بعداً ثبت شود؟» with buttons «ارسال بدون کد» and «انصراف». Same in the Accounts «آماده ارسال» flow (`openShip`): tracking is optional.
- Orders list: for `shipped` post orders without a code show a warning pill «منتظر کد رهگیری» plus days since shipped (from the `shipped` entry in `status_history`). Add a filter checkbox «بدون کد رهگیری» beside «فقط سنجاق‌شده‌ها».
- Accounts: new bucket «منتظر کد رهگیری» listing these orders with days since shipped and a row button «ثبت کد» (opens `UI.prompt`, calls `DB.setTracking`). Visible to both partners.
- As soon as a code is saved the Telegram channel message of that order is edited (section 9.3) and the other partner is notified (section 9.2).

---

## 7. IMPROVEMENTS

1. **Edit contact data of an order.** New RPC `update_order_info(p_order_id uuid, p_customer text, p_phone text, p_address text, p_postal_code text, p_note text)` (security definer, member only, same validation as `create_order`, not allowed on cancelled orders, sets `last_actor`) and an «ویرایش اطلاعات» button on the order card with a modal. Money fields are never editable.
2. **Old pending money warning.** In Accounts, mark orders in `awaiting_snapp` older than 14 days and orders in `paid` (not yet settled to the shop) older than 7 days with a warning pill and a pin shortcut.
3. **Products CSV export** (name, base price, page profit, available), UTF-8 with BOM via `UI.downloadCSV`.
4. **Backup reminder.** One line in the Settings About card: export the orders CSV weekly.
5. **Accessibility.** Every icon-only button has `aria-label`; focus returns to the trigger after a modal closes.

---

## 8. NOTIFICATIONS: WHO GETS WHAT

### 8.1 Recipients
- The actor (who made the change) is not notified. The other partner gets a Telegram DM and an iOS push.
- Events with no actor (daily reminder) notify both. Events that only the shop can cause (`prices_changed`, `availability_changed`) notify the page.

### 8.2 Events

| Kind | When | Recipient |
|---|---|---|
| `order_created` | new order | other partner, full invoice DM |
| `status_changed` | status change incl. cancelled | other partner |
| `tracking_changed` | code added/changed/cleared | other partner |
| `pin_changed` | pinned/unpinned (+note) | other partner |
| `prices_changed` | `set_base_price` / `bulk_price_update` | page; text «قیمت N محصول از مغازه به‌روز شد» |
| `availability_changed` | product toggled | page; ««{name}» ناموجود شد» / ««{name}» دوباره موجود شد» |
| `tracking_missing` | daily reminder | both |

Merge rule: events of the same order processed in one batch (for example `status_changed` to shipped plus `tracking_changed`) produce ONE DM and ONE push.

Event DM texts (Persian; the full invoice only for `order_created`):
- paid: «💵 پول سفارش {customer} رسید»
- settled (to the shop): «✅ تسویه شد. سفارش {customer} آماده ارسال است»
- shipped: «📦 سفارش {customer} ارسال شد» + code line or «⏳ کد رهگیری هنوز ثبت نشده»
- tracking changed (to the page): «🚚 کد رهگیری سفارش {customer}: <code>{code}</code>»
- cancelled: «❌ سفارش {customer} لغو شد»
- pin: «📌 سفارش {customer} سنجاق شد: {note}» / «سنجاق سفارش {customer} برداشته شد»
- tracking_missing: up to 10 customers with days since shipped: «⏳ این سفارش‌ها هنوز کد رهگیری ندارند: …»
Every DM has an inline URL button «باز کردن در اپ» to `${APP_URL}/?view=orders&order=${order.id}` (for product events: `?view=products`).

### 8.3 Full invoice DM (to either partner, no redaction needed)

```
🧾 فاکتور سفارش — {Jalali date and time}
👤 مشتری: {customer}
📞 تلفن: {phone}
📍 آدرس: {address}
📮 کد پستی: {postal_code}

🛍 کالاها:
• {name} × {qty} — {(base+hp)} تومان

🏷 تخفیف: {discount} (بر عهده {پیج|مغازه|نصف‌نصف})      (only if > 0)
🚚 ارسال: {پست|پیک} — {shipping_fee} تومان
💳 پرداخت: {نقدی|اسنپ‌پی}
💰 مبلغ کل مشتری: {total} تومان
(اسنپ‌پی) تسویه اسنپ‌پی: {payout} تومان

📊 حساب‌وکتاب
به مغازه: {owe}
سهم پیج: {h_share}

📌 وضعیت: {Persian status label}
🚚 کد رهگیری: {tracking or ⏳ هنوز ثبت نشده}
📝 یادداشت: {note}                                        (only if present)
```
`parse_mode: "HTML"`, escape all user data, Persian digits via `fa-IR`.

### 8.4 Push text (lock screen safe)
Short, no phone, no address, no amounts. Examples: title «سفارش جدید از پیج» or «سفارش جدید از مغازه», body `{customer}`; «آماده ارسال» / «سفارش {customer}»; «کد رهگیری ثبت شد» / `{customer}`; «محصول ناموجود شد» / `{name}`. Use `tag = order_id:kind` (or `product:<id>`), TTL 24 h.

---

## 9. NOTIFICATIONS: IMPLEMENTATION

### 9.1 Database (`migrations/003_notifications.sql` and `setup.sql`, idempotent)

```sql
create extension if not exists pg_net;
create extension if not exists pg_cron;

alter table public.orders
  add column if not exists last_actor uuid,
  add column if not exists tg_channel_msg_id bigint,
  add column if not exists tg_channel_hash text,
  add column if not exists tracking_reminded_at timestamptz;

create schema if not exists app_private;
create table if not exists app_private.config (key text primary key, value text not null);
revoke all on schema app_private from anon, authenticated;
revoke all on all tables in schema app_private from anon, authenticated;

create table if not exists public.outbox (
  id bigserial primary key, created_at timestamptz not null default now(),
  kind text not null, order_id uuid, actor uuid,
  payload jsonb not null default '{}'::jsonb,
  processed_at timestamptz, attempts int not null default 0, last_error text);
create index if not exists outbox_pending_idx on public.outbox (id) where processed_at is null;
alter table public.outbox enable row level security;          -- no policies: service role only

create table if not exists public.telegram_links (
  token text primary key, user_id uuid not null references auth.users on delete cascade,
  expires_at timestamptz not null, used boolean not null default false);
alter table public.telegram_links enable row level security;  -- no policies

create table if not exists public.telegram_chats (
  user_id uuid primary key references auth.users on delete cascade,
  chat_id bigint not null unique, connected_at timestamptz not null default now(),
  active boolean not null default true);
alter table public.telegram_chats enable row level security;  -- no policies

create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users on delete cascade,
  endpoint text not null unique, p256dh text not null, auth text not null,
  user_agent text, created_at timestamptz not null default now(), last_ok_at timestamptz);
alter table public.push_subscriptions enable row level security; -- no policies; RPCs only
```

RPCs (security definer, member only, grants as usual): `create_telegram_link()` returns a random 32-hex token valid 15 minutes; `my_notification_status()` returns `{telegram_connected, push_devices}`; `disconnect_telegram()`; `save_push_subscription(endpoint, p256dh, auth, user_agent)` (upsert by endpoint); `remove_push_subscription(endpoint)`.

`last_actor`: every RPC that mutates an order (`create_order`, `set_order_status`, `cancel_order`, `bulk_set_status`, `set_tracking`, `set_pin`, `update_order_info`) sets `last_actor = auth.uid()` in the same statement.

Triggers (security definer) write to `outbox`:
- AFTER INSERT on `orders`: `order_created`.
- AFTER UPDATE on `orders`, one row per real change: `status` changed gives `status_changed {from,to}`; `coalesce(tracking,'')` changed gives `tracking_changed {from,to}`; `pinned` (or `pin_note` while pinned) changed gives `pin_changed {pinned,note}`. `actor = NEW.last_actor`. Updates that touch only `tg_channel_msg_id`, `tg_channel_hash`, `tracking_reminded_at` create no event.
- AFTER UPDATE on `products`: `available` changed gives `availability_changed {name, available}`; `base_price` changes are collected by the RPCs `set_base_price` / `bulk_price_update`, which insert one `prices_changed {count}` row (no per-product spam).

Waking the Edge Function: AFTER INSERT trigger on `outbox` calls (inside an exception block so a failure never rolls back the order):

```sql
perform net.http_post(
  url := (select value from app_private.config where key = 'notify_url'),
  headers := jsonb_build_object('Content-Type','application/json',
              'x-webhook-secret', (select value from app_private.config where key = 'webhook_secret')),
  body := '{}'::jsonb);
```
Also a `pg_cron` job every 2 minutes calling the same URL; the function always processes ALL pending rows.

Daily reminder: `pg_cron` at 06:30 UTC (10:00 Asia/Tehran) inserts one `tracking_missing` row (payload `{order_ids}`) for orders with `status='shipped'`, `shipping_method='post'`, empty tracking, shipped more than 3 days ago (from `status_history`), and `tracking_reminded_at` null or older than 2 days; then sets `tracking_reminded_at = now()` for them. Skip when empty.

### 9.2 Edge Function `notify` (folder `supabase/functions/notify`, deploy with `--no-verify-jwt`)

Require header `x-webhook-secret === Deno.env.get('WEBHOOK_SECRET')`, else 401. Algorithm:
1. With the service role client claim up to 50 pending rows (`processed_at is null and attempts < 5`) ordered by id, incrementing `attempts` atomically (conditional update `... returning *`, or `for update skip locked` in an RPC) so overlapping invocations do not double-send.
2. Group by `order_id`, apply the merge rule, load the order, determine recipients (`profiles` roles, `telegram_chats`, `push_subscriptions`).
3. Send Telegram DMs, push notifications, and create/edit the channel message (9.3).
4. Mark rows `processed_at = now()` on success; on failure store `last_error` (max 500 chars) and leave `processed_at` null so the cron retries. One failing channel must not block the others.
5. Return `{processed, failed}`.

Shared helpers in `supabase/functions/_shared/`: `telegram.ts` (sendMessage, editMessageText, retry on HTTP 429 using `retry_after`, max 3), `push.ts`, `format.ts` (Persian money, Jalali date, HTML escape, message builders), `supabase.ts`.

### 9.3 Telegram channel message (minimal, one message per order)

Only: customer name, order registration date in the Jalali calendar, tracking code. Nothing else (no phone, address, amounts, items, status).

```
📦 سفارش جدید
👤 مشتری: <b>{customer}</b>
📅 تاریخ ثبت: {jalali date}
🚚 کد رهگیری: <code>{tracking}</code>
```
With an empty code the last line is `🚚 کد رهگیری: ⏳ هنوز ثبت نشده`. For a cancelled order append `❌ این سفارش لغو شد`.

Rules: create the message when `order_created` is processed and store `tg_channel_msg_id`. **As soon as `tracking_changed` is processed (a code added, changed or cleared, even days after shipping) call `editMessageText` so the code line is updated.** On cancellation edit to add the cancelled line. Idempotency: hash the final text into `tg_channel_hash`; skip the API call if unchanged; treat "message is not modified" as success. If the message no longer exists, send a new one and store the new id. Jalali date: `new Intl.DateTimeFormat('fa-IR-u-ca-persian', {year:'numeric', month:'2-digit', day:'2-digit', timeZone:'Asia/Tehran'}).format(new Date(order.created_at))`. The channel must be private (README).

### 9.4 Other Edge Functions
- `telegram-webhook` (`--no-verify-jwt`): verify header `X-Telegram-Bot-Api-Secret-Token` equals `TELEGRAM_WEBHOOK_SECRET`. `/start <token>`: find the unused, unexpired token, upsert `telegram_chats(user_id, chat_id)`, mark used, reply «✅ اتصال برقرار شد. از این پس اعلان‌ها و فاکتورها اینجا می‌آید.» `/start` without a valid token: «برای اتصال، از داخل اپ، بخش تنظیمات، دکمه «اتصال تلگرام» را بزنید.» `/stop`: `active = false`, reply «اعلان‌ها متوقف شد.» `/help`: short help. Ignore everything else and never reveal data to unlinked chats.
- `send-invoice` (JWT verification ON): body `{order_id}`; caller must be a member; sends the full invoice DM (8.3) to the caller's own active chat; returns `{ok:false, reason:'not_connected'}` when not linked. The order card gets a button «فاکتور در تلگرام من» (toast «فاکتور به تلگرام شما ارسال شد» or «ابتدا تلگرام را در تنظیمات وصل کنید»).
- `test-notify` (JWT verification ON): sends the caller a test DM «🔔 اعلان آزمایشی دلسانا» and a test push to all of their devices; returns which succeeded.

### 9.5 iOS Web Push

Requirements to respect: works only when installed to the Home Screen (iOS 16.4+), permission requested from a user tap, `manifest.json` has `display: "standalone"`, relative `start_url`, PNG icons 192 and 512; every push must show a visible notification.

- Frontend config: `vapidPublicKey`, `telegramBotUsername` in `app.js`.
- Settings screen, new card «اعلان‌ها»:
  1. «تلگرام»: status; button «اتصال تلگرام» (calls `create_telegram_link`, opens `https://t.me/<BOT>?start=<token>`); button «قطع اتصال».
  2. «اعلان روی گوشی»: unsupported browser gets an explanation; on iOS not standalone show «ابتدا اپ را به صفحه اصلی اضافه کنید: دکمه اشتراک‌گذاری (Share)، سپس Add to Home Screen، و بعد اپ را از صفحه اصلی باز کنید»; permission `default`: button «فعال‌سازی اعلان» (`Notification.requestPermission()` then `pushManager.subscribe({userVisibleOnly:true, applicationServerKey})` then `save_push_subscription`); permission `denied`: explain re-enabling in iOS Settings, Notifications; active: buttons «غیرفعال‌سازی» and «ارسال اعلان آزمایشی» (`test-notify`).
  3. On every app start with permission `granted`, silently re-check and re-save the subscription.
- `db.js`: wrappers for all new RPCs and the JWT functions (`supabase.functions.invoke`).
- Deep links: `app.js` reads `?view=<view>&order=<id>` on start and on notification click, switches view, clears filters if the order is hidden, scrolls to and briefly highlights `.order-card[data-order-id]` (retry until data is loaded). Optional `navigator.setAppBadge(pinnedCount)`.
- `sw.js` (cache version bumped, API/Function requests never cached): `push` handler parses `{title, body, url, tag}` and ALWAYS calls `showNotification(title, {body, tag, lang:'fa', dir:'rtl', icon:'icon-192.png', badge:'icon-192.png', data:{url}})` (fallback title «دلسانا»); `notificationclick` focuses an existing client and navigates to `data.url`, otherwise `clients.openWindow`; `pushsubscriptionchange` re-subscribes best effort.
- `push.ts`: use `npm:web-push` (or an equivalent maintained Deno Web Push library) with VAPID secrets; delete the subscription on HTTP 404/410; update `last_ok_at` on success.

### 9.6 Telegram and Supabase setup (write in README, step by step, for a non-developer; also give the Dashboard alternative for Edge Functions and Secrets)

1. @BotFather, `/newbot`, copy the token.
2. Create a PRIVATE channel; add the bot as administrator with permission to post messages.
3. Get the channel id (`-100…`): post a message in the channel, open `https://api.telegram.org/bot<TOKEN>/getUpdates`, read `chat.id` (a VPN may be needed).
4. Secrets: `TELEGRAM_BOT_TOKEN`, `TELEGRAM_BOT_USERNAME` (no @), `TELEGRAM_CHANNEL_ID`, `TELEGRAM_WEBHOOK_SECRET`, `WEBHOOK_SECRET`, `APP_URL` (GitHub Pages URL without trailing slash), `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT` (`mailto:…`).
5. Deploy: `notify` and `telegram-webhook` with `--no-verify-jwt`; `send-invoice` and `test-notify` with JWT verification.
6. Register the webhook once: `https://api.telegram.org/bot<TOKEN>/setWebhook?url=https://<ref>.supabase.co/functions/v1/telegram-webhook&secret_token=<TELEGRAM_WEBHOOK_SECRET>`.
7. SQL Editor: `insert into app_private.config values ('notify_url','https://<ref>.supabase.co/functions/v1/notify'),('webhook_secret','<WEBHOOK_SECRET>') on conflict (key) do update set value = excluded.value;`
8. VAPID keys: `npx web-push generate-vapid-keys`; the public key goes into `app.js`, both keys into secrets.
9. Each partner opens Settings, taps «اتصال تلگرام», then Start in the bot chat.
Note in README: Telegram is filtered in Iran, so reading the bot/channel needs a VPN, but Edge Functions run outside Iran and can call Telegram normally.

---

## 10. SQL FILES SUMMARY

- `setup.sql`: equals "all migrations applied" for fresh installs.
- `migrations/001_security.sql` (5.4, 5.5, 5.15), `migrations/002_simplify_products.sql` (section 3.4), `migrations/003_notifications.sql` (section 9.1 plus the relaxed `shipped` rule, `update_order_info`, extended `bulk_set_status`). All idempotent (`create or replace`, `drop ... if exists`, `add column if not exists`).
- README "Upgrading": back up (CSV export of orders, `select * from product_costs`, `select * from order_private`), run 001, 002, 003 in order, disable public sign-up, set secrets, deploy functions, set webhook, fill `app_private.config`.

---

## 11. SECURITY CHECKLIST (verify before finishing)

- No secret in any committed file (search for `token`, `secret`, `VAPID_PRIVATE`, `service_role`).
- `outbox`, `telegram_links`, `telegram_chats`, `push_subscriptions`, `app_private.config` have no client access; only RPCs and the service role use them.
- `notify` and `telegram-webhook` reject requests without the correct secret header.
- A user without a `profiles` row cannot call any RPC or JWT function and cannot read orders or products.
- Customer data goes only to the two linked private chats and (customer name only) the private channel. Push text contains no phone, address or amounts.

---

## 12. TESTS

Automated (`tests.html` for JS; `supabase/functions/_shared/format.test.ts` for Deno):
1. All money examples and the invariant from section 2 (with `calc.js` taking `{qty, base, hp}`), including rounding regressions 11 and 12 and the error case 13.
2. Parsing tests of 5.14.
3. Jalali date formatter for a known timestamp in `Asia/Tehran`.
4. Channel message builder: with and without tracking; cancelled variant; HTML escaping of `<b>` in a customer name.
5. DM builder: includes `owe` and `h_share`, contains no cost or shop-profit text.
6. Merge rule: `status_changed(shipped)` plus `tracking_changed` for one order gives a single message.

Manual checklist (README, "Testing"):
1. Log in as the shop: chip says «مغازه»; as the page: «پیج»; no old names anywhere.
2. Add a product (shop price 500,000, page profit 150,000): cash + post total 840,000, owed to shop 690,000, page share 150,000; Snapp + post 940,000; a 350,000 unit with Snapp + post is 595,000 in the form and in the stored order.
3. Discount 50,000 with each bearer gives owe 690,000 / 640,000 / 665,000 and page share 100,000 / 150,000 / 125,000.
4. Shop taps «عدم موجودی» on a product: it dims, cannot be added to a new order, the server rejects it too, and the page gets a push/DM. Tap «موجود شد»: back to normal. The page account sees no toggle. Existing orders are unaffected.
5. Settings: set post fee to 0, save, reload: it stays 0; set Snapp multiplier 1.2: new Snapp orders use it, old ones unchanged.
6. Page creates an order: the shop gets the full invoice DM; the channel gets «📦 سفارش جدید» with name, Jalali date and «⏳ هنوز ثبت نشده».
7. Shop marks it shipped without a code (confirm dialog): the page is notified; the order shows «منتظر کد رهگیری» with day count and appears in the Accounts bucket.
8. Force the daily cron: both partners get one reminder.
9. Shop saves the code: within seconds the channel message shows the code and the page gets «کد رهگیری سفارش …». Change the code: the message updates; clear it: the «⏳» line returns.
10. Cancel an order: the channel message shows the cancelled line; the other partner is notified; reports exclude it.
11. iPhone: install to the Home Screen, enable notifications in Settings, use the test button, then create an order from the other phone: a push arrives and tapping it opens that order.
12. Break the Telegram token temporarily: orders still save; failed outbox rows keep `last_error`; after fixing, the retry delivers them.
13. An outsider cannot sign up, and a user without a profile cannot read data or call RPCs.
14. Old orders created before the migration still display correctly.

---

## 13. PHASES (verify and report after each)

1. `calc.js` rewrite for the v2 model and rounding fix, all new tests in `tests.html` pass (sections 2 and 12).
2. SQL: migrations 001 and 002 and the matching `setup.sql` (security, product model, RPCs, `create_order`, cancel). Test with manual SQL.
3. Frontend for the new product model and availability toggle, display-name change (sections 3.3 and 4), `db.js` fixes (5.2, 5.3), `ui.js` parsing (5.14), order form and cards, reports and CSV.
4. Screens fixes and flows: sections 5.7 to 5.13 and 6, improvements 7.1 to 7.5.
5. Migration 003 and Edge Functions: outbox, `notify`, channel create/edit, DMs; verify the tracking-added-later flow.
6. `telegram-webhook`, Settings «اتصال تلگرام», `send-invoice`.
7. Web Push (`sw.js`, subscription UI, `push.ts`, `test-notify`, deep links), tested on a real iPhone Home Screen app.
8. Cleanup (5.16), README (setup, upgrading, testing), `CHANGELOG.md`, security checklist, final review of every numbered item in this file; list anything not done and why.
