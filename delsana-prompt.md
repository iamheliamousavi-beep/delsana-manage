# ROLE
You are a senior full-stack engineer. Build a complete, working, production-ready web app called "Delsana Management" using ONLY plain HTML, CSS and vanilla JavaScript (no frameworks, no build step, no npm). Do not ask me questions. If something is ambiguous, pick the most sensible option, write the assumption in README.md, and continue. Work in the phases listed at the end and verify each phase before moving on.

# BUSINESS CONTEXT
Two people run a small cosmetics business:
- MAHDI owns a physical cosmetics shop. He buys goods from the wholesale market, adds his own profit, and sells to Helia.
- HELIA runs an Instagram page. She buys from Mahdi, adds her own profit, and sells to end customers.
Flow of an order:
1. A customer buys from Helia's Instagram page. The customer's money arrives in HELIA's bank account.
2. Helia keeps her own profit and transfers the rest to Mahdi: (purchase cost + Mahdi's profit, adjusted by any discount he bears) + the shipping fee if shipping is by post.
3. After receiving the money, Mahdi takes the goods from his shop and ships them (by post with a tracking code, or by local courier).
Customers can pay in cash/card or with "Snapp Pay" (installment service). With Snapp Pay the money does NOT arrive immediately; it arrives later when Snapp Pay settles. So the app must track "sold but money not yet received".

Problems the app must solve:
- Tracking codes get lost; they need to find who bought what and with which code.
- Nobody knows exactly who owes whom and how much.
- Snapp Pay money arrives late, so pending amounts must be tracked and then split correctly.
- Helia constantly phones Mahdi to ask about stock and price. She must see live stock and prices.
- Market prices fluctuate; Mahdi must update prices fast, and reports must be fast and accurate.
- Problematic orders (not delivered, returned, complaint) get forgotten; they must be easy to pin and follow up.

# USERS AND ROLES
Exactly two users (Supabase Auth, email + password). No public sign-up.
- role "mahdi": full access. Sets purchase cost, his own profit per product, and stock. Sees all profit figures.
- role "helia": sets ONLY her own profit per product. Sees "price from Mahdi" (= cost + Mahdi's profit) but must NOT see Mahdi's purchase cost or Mahdi's profit breakdown, and must NOT see Mahdi's profit totals. She sees her own profit and the amount she owes Mahdi. She can create orders and update order status.
Enforce this in the database with Row Level Security, not only in the UI.

# MONEY RULES (currency: toman, integers only, never floats except the Snapp multiplier, which must be applied then rounded)
Per product: cost (purchase price from market), mp (Mahdi's profit), hp (Helia's profit).
- base = cost + mp (what Helia owes Mahdi per unit)
- unit_sum = cost + mp + hp

Per order inputs:
- items with quantity q
- discount D (toman, >= 0)
- discount_bearer: one of "helia" | "mahdi" | "split"
- shipping_method: "post" | "courier"
- payment method: "cash" | "snapp"
- snapp_multiplier (default from settings, editable per order for Snapp orders)

Settings (editable in the Settings screen, stored in DB): post_fee (default 190000), snapp_multiplier (default 1.15), rounding_step (default 5000). Every order stores a SNAPSHOT of the values it used (shipping_fee, snapp_multiplier, rounding_step), so changing settings later never changes old orders.

Calculations:
- shipping_fee = (shipping_method == "post") ? post_fee : 0
- sub = sum(q * unit_sum)
- net = sub - D   (D must not exceed sub)
- Discount split: if bearer == "helia": helia_discount = D, mahdi_discount = 0. If "mahdi": mahdi_discount = D, helia_discount = 0. If "split": mahdi_discount = floor(D / 2), helia_discount = D - mahdi_discount.
- CASH total charged to customer = net + shipping_fee
- SNAPP total charged to customer = roundToStep(net * snapp_multiplier) + shipping_fee, where roundToStep(x) = Math.round(x / rounding_step) * rounding_step. The extra percentage is Snapp Pay's fee. Snapp Pay deposits to Helia's account the same amount as a cash sale: payout = net + shipping_fee (the fee and the rounding difference never belong to Mahdi or Helia).
- owe_to_mahdi = sum(q * base) - mahdi_discount + shipping_fee
- helia_share = sum(q * hp) - helia_discount
- mahdi_profit = sum(q * mp) - mahdi_discount
- Invariant (assert it in code and in tests): owe_to_mahdi + helia_share == net + shipping_fee.
- Show a warning (do not block) if mahdi_profit or helia_share would be negative.
Prices on an order are SNAPSHOTS: store cost, mp, hp and base for each line item at order time. Later price changes must never alter old orders.

Worked examples (use as unit tests). Product: qty 1, cost 400,000, mp 100,000, hp 150,000 (unit_sum 650,000, base 500,000), post_fee 190,000, rounding_step 5000.
1. Cash, post, no discount: total 840,000; owe 690,000; helia_share 150,000; mahdi_profit 100,000.
2. Cash, courier, no discount: total 650,000; owe 500,000; helia_share 150,000; mahdi_profit 100,000.
3. Snapp 1.15, post, no discount: 650,000*1.15 = 747,500 -> 750,000; total 940,000; payout 840,000; owe 690,000; helia_share 150,000.
4. Snapp 1.15, courier, no discount: total 750,000; payout 650,000; owe 500,000.
5. Snapp 1.2, post, no discount: 650,000*1.2 = 780,000; total 970,000; payout 840,000.
6. Cash, post, discount 50,000, bearer helia: total 790,000; owe 690,000; helia_share 100,000; mahdi_profit 100,000.
7. Same, bearer mahdi: total 790,000; owe 640,000; helia_share 150,000; mahdi_profit 50,000.
8. Same, bearer split: total 790,000; owe 665,000; helia_share 125,000; mahdi_profit 75,000.
9. Cash, post, discount 50,001, bearer split: mahdi_discount 25,000; helia_discount 25,001; owe 665,000; helia_share 124,999; mahdi_profit 75,000.
10. Snapp 1.15, post, discount 50,000, bearer helia: net 600,000; 690,000 + 190,000 = total 880,000; payout 790,000.
Write these as automated checks in tests.html that run the calc function and show PASS/FAIL, plus the invariant check for each case.

# ORDER STATUS FLOW
Statuses: new -> (snapp only) awaiting_snapp -> paid (money received in Helia's account) -> settled (Helia transferred owe_to_mahdi to Mahdi) -> shipped (Mahdi posted it / handed it to the courier) -> optionally delivered. Also: cancelled.
- Cash orders start at "paid" or "new" (user chooses when creating; default "new"). Snapp orders start at "awaiting_snapp".
- Each status change records a timestamp (status_history jsonb array).
- Mahdi sees a clear "Ready to ship" list: orders that are settled but not shipped. For post orders the tracking code is required when marking as shipped; for courier orders it is optional (allow a free-text note, e.g. courier name).

# FEATURES
1. Login screen; the session persists; logout button.
2. Products screen: list with search. Mahdi edits name, stock, cost, mp. Helia edits hp. Show live cash price and Snapp price (rounded, using the current settings) for each product, excluding shipping. Low-stock highlight (stock <= 2). Mahdi can add products and archive them (not delete). Bulk price update for Mahdi: select several products and apply a percentage or fixed-amount change to cost.
3. New order screen: pick products + quantity (searchable, show stock), customer name, phone, address, POSTAL CODE (10 digits, validated, accepts Persian digits), shipping method (post / courier), payment method (cash / snapp), optional per-order Snapp multiplier override (visible only when Snapp is selected, defaulting to the setting), discount amount, DISCOUNT BEARER selector (Helia / Mahdi / split equally; visible only when discount > 0), optional note. Live-updating summary showing: total for customer, shipping fee, amount owed to Mahdi, Helia's share, and (for Mahdi's account only) Mahdi's profit. Warn (don't block) if qty exceeds stock. On save: decrement stock and create the order with snapshots.
4. Orders screen: list sorted with PINNED orders first, then newest first. Search by customer name, phone, postal code, product name, or tracking code. Filters: status, payment method, shipping method, "pinned only". Each order card shows items, amounts, discount and who bears it, shipping method, postal code, status (change via dropdown/buttons), tracking code (editable by both partners). Cancel order: restore stock, mark "cancelled", exclude from reports.
   PINNING: each order has a pin/unpin button (both partners can use it) and an optional pin note (reason, e.g. "not delivered, customer complained"). Pinned orders show a highlighted card and a pin icon, and always appear at the top of the list. The Orders tab shows a badge with the number of pinned orders. Provide a "Pinned" quick filter. Store pinned (boolean), pin_note, pinned_at.
5. Accounts screen:
   - Helia currently owes Mahdi = sum of owe_to_mahdi for orders in status "paid".
   - Snapp Pay pending = sum of payout for orders in "awaiting_snapp".
   - Lists of orders in each bucket and a button "Mark all selected as settled".
6. Reports screen: ranges Today / 7 days / 30 days / All / custom dates (cancelled orders excluded). Show: order count, total sales, Helia's profit (helia_share), top 5 products by quantity, Snapp vs cash split, post vs courier count, total discounts given broken down by who bore them. Mahdi's profit total is shown ONLY to Mahdi's account.
7. Settings screen: post_fee (default 190000), snapp_multiplier (default 1.15), rounding_step (default 5000). Both partners can edit. Changes apply to new orders only. Show a note about this.
8. CSV export of all orders (UTF-8 with BOM so Excel shows Persian correctly), including postal code, shipping method, discount, bearer, status, tracking, pinned.

# UI / UX
- Persian (Farsi) UI, RTL (dir="rtl"), font Vazirmatn from Google Fonts with Tahoma fallback. Display dates in the Jalali calendar via Intl.DateTimeFormat('fa-IR-u-ca-persian'). Show numbers with thousand separators; accept Persian/Arabic digits in inputs and convert them to English digits before saving.
- Mobile-first, works well on a phone and on Windows desktop. Tab navigation, large touch targets, no horizontal scroll.
- Light and dark theme following the system. Brand color pink/magenta (#b83280). Clean, modern, calm design; consistent spacing; loading states; clear error messages in Persian; confirmation dialog for destructive actions.
- Escape all user-provided text before inserting into HTML (prevent XSS).

# TECH AND DATA
- Frontend: static files only: index.html, style.css, app.js (you may split into small ES modules: db.js, calc.js, ui.js), manifest.json, sw.js, tests.html. Load @supabase/supabase-js (pinned exact version) from the jsDelivr CDN.
- Backend: Supabase (free tier). Provide setup.sql that I can paste into the SQL Editor, containing:
  - profiles(user_id uuid pk references auth.users, role text check in ('mahdi','helia'))
  - function is_mahdi() security definer
  - products(id, name, stock, hp, base_price, archived, created_at)  -- readable by both; base_price = cost + mp
  - product_costs(product_id pk, cost, mp)  -- readable/writable ONLY by Mahdi
  - trigger: when product_costs changes, update products.base_price
  - orders(id, created_at, customer, phone, address, postal_code, items jsonb, method, shipping_method, shipping_fee, snapp_multiplier, rounding_step, discount, discount_bearer, mahdi_discount, helia_discount, total, owe, h_share, payout, status, status_history jsonb, tracking, note, pinned boolean default false, pin_note, pinned_at); each item in items holds {product_id, name, qty, base, hp}
  - order_private(order_id pk, cost_total, m_profit)  -- ONLY Mahdi can read. Order creation (from either user) goes through an RPC function create_order(...) (security definer) that computes all amounts and the private values on the server from product_costs and settings, so Helia never needs to read costs. The RPC must validate inputs (postal code format, discount <= sub, valid enums) and re-compute everything server-side instead of trusting client numbers.
  - settings(key, value) with defaults inserted
  - RLS policies for every table; indexes on orders(created_at), orders(status), orders(tracking), orders(pinned)
  Keep stock decrement and order creation atomic inside the create_order RPC. Also provide RPCs or policies for cancel_order (restores stock atomically).
- The app config (Supabase URL and anon key) lives in one clearly marked config object at the top of app.js.
- Hosting: GitHub Pages. Use only relative paths so it works from a sub-path.
- PWA: valid manifest (name, short_name, rtl, standalone, theme color, an inline SVG icon plus 192/512 PNG placeholders), and a service worker with network-first strategy for API calls and cache-first for static assets so the app shell opens offline and installs on Android and Windows (Chrome/Edge "Install").
- Use Supabase Realtime or polling so a change by one partner appears on the other's screen without a manual refresh.

# FILES TO DELIVER
index.html, style.css, app.js (+ modules if used), manifest.json, sw.js, tests.html, setup.sql, README.md (in English, with step-by-step: create Supabase project, run setup.sql, create the two users, insert their rows in profiles, fill config, deploy to GitHub Pages, install the PWA, and a list of assumptions).

# QUALITY RULES
- No placeholder code, no TODOs, no "implement later". Every button must work.
- Money values are integers. All calculations live in ONE pure function file (calc.js) reused by the UI and tests.html; the server-side create_order must implement the same formulas.
- Handle errors from every Supabase call and show a Persian message.
- Never expose the service_role key. Only the anon key in the frontend.
- Validate inputs (non-negative numbers, required fields, postal code is exactly 10 digits).

# WORKFLOW (follow strictly)
Phase 1: write setup.sql and calc.js + tests.html; confirm all 10 worked examples and the invariant PASS.
Phase 2: auth, layout, navigation, theme, RTL, number/date helpers.
Phase 3: products screen with role-based editing and bulk price update.
Phase 4: new order screen (postal code, shipping method, discount bearer, Snapp multiplier override) and the create_order RPC flow.
Phase 5: orders screen with status flow, tracking code, search, filters, pinning with note and badge, cancel.
Phase 6: accounts screen, reports, CSV export, settings.
Phase 7: PWA files, realtime updates, README.md, and a final review of every requirement above against the code; fix anything missing.
After each phase, briefly state what was completed and what you verified.
