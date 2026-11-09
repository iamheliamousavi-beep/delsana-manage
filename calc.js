/* calc.js — the single source of truth for all money calculations.
   Pure functions, integers only (toman). The only float allowed is the
   Snapp multiplier, which is applied and then rounded to rounding_step.
   The same formulas are implemented server-side in setup.sql (create_order
   via order_amounts) and mirrored by tests.html.

   v2 model: a product has only `base` (shop price per unit) and `hp`
   (page profit per unit).  There is no cost, no shop profit and no stock.
   v3 model: adds the `mixed` payment method (part Snapp Pay + part cash).
   Cash and snapp results are byte-for-byte identical to v2.
   v4 model (follow-up): the mixed Snapp part S is the customer's exact
   Snapp charge; the Snapp fee (snappRound(S)-S, clamped to 0 with a
   warning for tiny S) is paid in cash.
   v5 model (split fee fix): the fee is collected INSIDE the Snapp amount.
   The customer pays a cash part C (goods only, no fee) and a Snapp part P
   that already includes the fee on the goods covered by Snapp:
     remainingGoods = net - C          (cash reduces the Snapp-covered goods)
     expectedSnap   = round1000(remainingGoods * multiplier)
     validation:    |P - expectedSnap| <= MIXED_TOLERANCE
   Old rows (fee inside the recorded cash part) keep the v4 path via the
   fee_in_snapp flag, so legacy orders never change displayed values.
   v6/v7 model (Snap Pay settles to the SHOP): Snap Pay always deposits the
   customer's Snapp payment into the SHOP's account; the cash/card part is
   received by the page. `owe` is the SHOP's entitlement (not a transfer
   from the page) and `h_share` the page's. The Snap-paid goods money is
   split between the two partners in the ratio of their entitlements:
     shipSnap   = shipping_fee if shipping was paid via Snapp, else 0
     net        = (owe - shipping_fee) + h_share   (goods value after discount)
     goodsSnap  = snapp_deposit - shipSnap          (goods money via Snap Pay)
     page_claim = 0    if net <= 0 or h_share <= 0 or goodsSnap <= 0
                = min(goodsSnap, round_half_up(h_share * goodsSnap / net))
     page_debt  = owe - snapp_deposit + page_claim  (always >= 0)
   page_claim is the page's claim ON the shop («طلب پیج از مغازه»);
   page_debt is the page's debt TO the shop («بدهی پیج به مغازه»).
   The two accounts are independent and are never netted. Conservation:
   (snapp_deposit - page_claim) + page_debt = owe. See Calc.pageSplit. */
(function (root) {
  'use strict';

  var BEARERS = ['helia', 'mahdi', 'split'];
  var SHIPPING = ['post', 'courier'];
  var METHODS = ['cash', 'snapp', 'mixed'];
  /* how the shipping fee itself is paid: cash (or card, same channel) / Snapp */
  var SHIPPING_PAYMENTS = ['cash', 'snapp'];
  var MAX_SAFE = 9007199254740991;

  /* Float-safe rounding to a step.
     Without the 1e-9 nudge a value that should land exactly on a .5
     boundary (e.g. 402500 / 5000 = 80.5) can arrive as 80.49999999999999
     because of float noise and round down, giving a different result than
     the exact `numeric` math used by Postgres. */
  function roundToStep(x, step) {
    if (!isFinite(x)) throw new Error('roundToStep: مقدار عدد نیست');
    var s = Math.floor(Math.abs(step)) > 0 ? Math.floor(Math.abs(step)) : 1;
    return Math.round(x / s + 1e-9) * s;
  }

  /* Exact snapp rounding: round(amount × multiplier / step) × step, half up
     for positives — identical to Postgres round(amount × mult / step) × step.
     The multiplier is converted to an exact rational from its DECIMAL STRING
     (String(mult)), never from float arithmetic, so 1.15 is exactly 115/100.
     (String(1.15) === "1.15": shortest-round-trip printing recovers the
     decimals the value was created from; both JS and Postgres parse the same
     JSON decimal text, so both sides compute the same integers.)
     Parsed rationals are cached: same input string always hits the same entry. */
  var multCache = {};
  function parseMultiplierRational(mult) {
    var key = String(mult);
    if (multCache[key]) return multCache[key];
    var n = Number(mult);
    if (!isFinite(n) || n <= 0 || n > 10) throw new Error('ضریب اسنپ‌پی نامعتبر است');
    var m = /^(\d+)(?:\.(\d+))?(?:[eE]([+-]?\d+))?$/.exec(String(mult).trim());
    if (!m) throw new Error('ضریب اسنپ‌پی نامعتبر است');
    var digits = m[1] + (m[2] || '');
    var a = BigInt(digits);
    var b = 10n ** BigInt((m[2] || '').length);
    var exp = m[3] ? parseInt(m[3], 10) : 0;
    if (exp > 0) a = a * (10n ** BigInt(exp));
    else if (exp < 0) b = b * (10n ** BigInt(-exp));
    if (a <= 0n) throw new Error('ضریب اسنپ‌پی نامعتبر است');
    var r = { a: a, b: b };
    multCache[key] = r;
    return r;
  }

  function snappRound(amount, multiplier, step) {
    var n = Number(amount);
    if (!isFinite(n) || Math.floor(n) !== n || n < 0 || n > MAX_SAFE) {
      throw new Error('snappRound: مقدار باید عدد صحیح نامنفی باشد');
    }
    var s = Math.floor(Number(step));
    if (!isFinite(s) || s <= 0) throw new Error('گرد کردن باید عدد مثبت باشد');
    var r = parseMultiplierRational(multiplier);
    /* floor((2·n·a + b·s) / (2·b·s)) · s: exact round-half-up for positives.
       Always BigInt — exact at every magnitude, no float floor hazard. */
    var q = (2n * BigInt(n) * r.a + r.b * BigInt(s)) / (2n * r.b * BigInt(s));
    return Number(q * BigInt(s));
  }

  /* Persian/Arabic digits -> ASCII (calc.js stays dependency-free). */
  var FA_DIGITS = '۰۱۲۳۴۵۶۷۸۹';
  var AR_DIGITS = '٠١٢٣٤٥٦٧٨٩';
  function toEnDigits(s) {
    return String(s === null || s === undefined ? '' : s)
      .replace(/[۰-۹]/g, function (d) { return String(FA_DIGITS.indexOf(d)); })
      .replace(/[٠-٩]/g, function (d) { return String(AR_DIGITS.indexOf(d)); });
  }

  var SNAPP_PART_MSG = 'مبلغ اسنپ‌پی باید عدد صحیح و حداقل ۱ باشد';
  var CASH_PART_MSG = 'مبلغ نقدی باید عدد صحیح و ۰ یا بیشتر باشد';
  /* Parse a toman amount (single source of truth for the number rule in
     the new-order form AND the tests): Persian/Arabic digits, thousand
     separators and a trailing-dash minus are accepted; a fractional value
     (1.5, ۵٫۵) is an error, never silently truncated. Throws msg. */
  function parseMoney(text, msg) {
    if (text === null || text === undefined) throw new Error(msg);
    var t = toEnDigits(text).replace(/[\u2212\u2013\u2014]/g, '-').replace(/[\s,٬]/g, '');
    var m = /^(-?)(\d+)(?:[\.\u066B](\d+))?$/.exec(t);
    if (!m) throw new Error(msg);
    if (m[3] && !/^0+$/.test(m[3])) throw new Error(msg);
    var v = Number((m[1] || '') + m[2]);
    if (!isFinite(v) || v < 0 || v > MAX_SAFE) throw new Error(msg);
    return v;
  }
  /* Parse the raw Snapp-part input: a positive integer toman (0 is
     rejected — a mixed order without a Snapp part is the cash method). */
  function parseSnappPart(text) {
    var v = parseMoney(text, SNAPP_PART_MSG);
    if (v < 1) throw new Error(SNAPP_PART_MSG);
    return v;
  }
  /* Parse the raw cash-part input (v5 mixed): a non-negative integer. */
  function parseCashPart(text) {
    return parseMoney(text, CASH_PART_MSG);
  }

  /* v5 mixed constants. Suggestion amounts are shown rounded to the
     nearest 1000; the entered Snapp amount (which already contains the
     fee and is often a rounded number the customer actually paid) may
     drift from the expected value by at most MIXED_TOLERANCE toman. */
  var MIXED_ROUND = 1000;
  var MIXED_TOLERANCE = 5000;

  /* Exact half-up round of amount / multiplier — the goods value inside a
     Snapp charge that already includes the fee (v5 mixed). Equals
     round(amount × b / a) for the multiplier rational a/b, BigInt-exact. */
  function snappInverseRound(amount, multiplier) {
    var n = Number(amount);
    if (!isFinite(n) || Math.floor(n) !== n || n < 0 || n > MAX_SAFE) {
      throw new Error('snappInverseRound: مقدار باید عدد صحیح نامنفی باشد');
    }
    var r = parseMultiplierRational(multiplier);
    var q = (2n * BigInt(n) * r.b + r.a) / (2n * r.a);
    return Number(q);
  }

  /* Split the discount between the two partners.
     helia pays it -> helia_discount = D; mahdi pays it -> mahdi_discount = D;
     split -> mahdi takes floor(D/2), helia takes the rest. */
  function splitDiscount(D, bearer) {
    var d = Math.floor(D);
    if (d < 0) throw new Error('تخفیف نباید منفی باشد');
    if (BEARERS.indexOf(bearer) === -1) throw new Error('بر عهده تخفیف نامعتبر است');
    if (bearer === 'helia') return { mahdi_discount: 0, helia_discount: d };
    if (bearer === 'mahdi') return { mahdi_discount: d, helia_discount: 0 };
    var md = Math.floor(d / 2);
    return { mahdi_discount: md, helia_discount: d - md };
  }

  /* inputs:
       items: [{ qty, base, hp }]      (order snapshots)
       discount, discount_bearer
       shipping_method: 'post'|'courier'
       payment_method:  'cash'|'snapp'|'mixed'  (how the goods are paid)
       shipping_payment_method: 'cash'|'snapp'  (how the shipping fee is paid;
         omitted -> follows the goods method, mixed -> cash, matching old rows)
       post_fee, snapp_multiplier, rounding_step      (settings/snapshot values)
       snapp_part: the Snapp charge P (mixed only; cash/snapp must send null/0)
       cash_part:  v5 mixed only — the cash part C (non-Snapp goods payment)
       fee_in_snapp: v5 flag — true for rows created by the v5 model; absent
         or false = legacy v4 semantics (fee inside cash_charge)
     returns every derived amount as integers. */
  function calcOrder(inp) {
    if (!inp || !Array.isArray(inp.items)) throw new Error('لیست کالاها الزامی است');

    var postFee = Math.floor(Number(inp.post_fee) || 0);
    var step = Math.floor(Number(inp.rounding_step) || 1);
    var mult = Number(inp.snapp_multiplier);
    if (!isFinite(mult)) mult = 1;
    var bearer = inp.discount_bearer || 'helia';
    var ship = inp.shipping_method || 'courier';
    var method = inp.payment_method || inp.goods_payment_method || 'cash';
    var shipPay = inp.shipping_payment_method;
    if (shipPay === undefined || shipPay === null || shipPay === '') {
      shipPay = method === 'mixed' ? 'cash' : method;
    }

    if (BEARERS.indexOf(bearer) === -1) throw new Error('بر عهده تخفیف نامعتبر است');
    if (SHIPPING.indexOf(ship) === -1) throw new Error('روش ارسال نامعتبر است');
    if (METHODS.indexOf(method) === -1) throw new Error('روش پرداخت نامعتبر است');
    if (SHIPPING_PAYMENTS.indexOf(shipPay) === -1) throw new Error('روش پرداخت هزینه ارسال نامعتبر است');

    var sub = 0, baseSum = 0, hpSum = 0;
    for (var i = 0; i < inp.items.length; i++) {
      var it = inp.items[i];
      var q = Math.floor(Number(it.qty) || 0);
      var base = Math.floor(Number(it.base) || 0);
      var hp = Math.floor(Number(it.hp) || 0);
      if (q <= 0) throw new Error('تعداد باید حداقل ۱ باشد');
      if (base < 0 || hp < 0) throw new Error('قیمت نباید منفی باشد');
      sub += q * (base + hp);
      baseSum += q * base;
      hpSum += q * hp;
    }

    var discount = Math.floor(Number(inp.discount) || 0);
    if (discount < 0) throw new Error('تخفیف نباید منفی باشد');
    if (discount > sub) throw new Error('تخفیف از مبلغ کالاها بیشتر است');

    var split = splitDiscount(discount, bearer);
    var mahdi_discount = split.mahdi_discount;
    var helia_discount = split.helia_discount;

    var shipping_fee = ship === 'post' ? postFee : 0;
    var net = sub - discount;

    /* A Snapp part on a cash/snapp order is rejected, never ignored. */
    var sRaw = inp.snapp_part;
    var sProvided = !(sRaw === undefined || sRaw === null || sRaw === '' || Number(sRaw) === 0);
    if (method !== 'mixed' && sProvided) {
      throw new Error('مبلغ اسنپ‌پی فقط برای پرداخت ترکیبی است');
    }

    /* Snapp Pay settles the same amount a cash sale would produce. */
    var payout = net + shipping_fee;

    /* the shipping fee is never multiplied; it is simply routed to the
       channel the seller picked for it */
    var shipping_snapp = shipPay === 'snapp' ? shipping_fee : 0;
    var shipping_cash = shipping_fee - shipping_snapp;

    var customer_total;
    var snapp_part = 0, snapp_charge = 0, cash_charge = 0;
    var snapp_deposit = 0, snapp_fee = 0, snapp_fee_clamped = false;
    var goods_snapp_charge = 0, goods_cash_charge = 0;
    var cash_part = 0, remaining_goods = 0, expected_snapp = 0;
    /* fee_in_snapp=true (v5, new rows): the fee lives inside the Snapp
       amount — the cash part covers goods only.
       fee_in_snapp=false/absent (legacy, pre-012 rows): v4 semantics. */
    var feeInSnapp = !!inp.fee_in_snapp;
    if (method === 'mixed' && feeInSnapp) {
      var C = parseCashPart(inp.cash_part);
      var P = parseSnappPart(sRaw);
      var remaining = net - C;
      if (remaining <= 0) {
        throw new Error('مبلغ نقدی نباید از مبلغ کالاها پس از تخفیف بیشتر یا برابر باشد؛ برای پرداخت کامل از روش نقدی استفاده کنید');
      }
      var expectedSnap = snappRound(remaining, mult, MIXED_ROUND);
      if (Math.abs(P - expectedSnap) > MIXED_TOLERANCE) {
        throw new Error('مبلغ اسنپ‌پی واردشده ' + P + ' تومان با نقدی ' + C + ' تومان هم‌خوانی ندارد؛ مبلغ مورد انتظار اسنپ‌پی ' + expectedSnap + ' تومان است');
      }
      snapp_fee = C + P - net;
      if (snapp_fee < 0) {
        throw new Error('مبلغ اسنپ‌پی واردشده ' + P + ' تومان از باقی‌مانده کالاها ('
          + remaining + ' تومان) بعد از نقدی کمتر است؛ نقدی و مبلغ اسنپ‌پی را با هم بررسی کنید');
      }
      snapp_part = P;
      cash_part = C;
      remaining_goods = remaining;
      expected_snapp = expectedSnap;
      goods_snapp_charge = P;
      goods_cash_charge = C;
      snapp_charge = P + shipping_snapp;
      cash_charge = C + shipping_cash;
      snapp_deposit = remaining + shipping_snapp;
      customer_total = snapp_charge + cash_charge;
      snapp_fee_clamped = false;
    } else if (method === 'mixed') {
      var S = parseSnappPart(sRaw);
      if (S >= net) {
        throw new Error('مبلغ اسنپ‌پی باید کمتر از مبلغ کالاها پس از تخفیف باشد؛ برای پرداخت کامل از روش اسنپ‌پی یا نقدی استفاده کنید');
      }
      var rounded = snappRound(S, mult, step);
      if (rounded < S) {
        /* tiny S: the fee is clamped to 0 (non-blocking warning) */
        snapp_fee = 0;
        snapp_fee_clamped = true;
      } else {
        snapp_fee = rounded - S;
        snapp_fee_clamped = false;
      }
      if (!(snapp_fee < S)) {
        throw new Error('کارمزد اسنپ‌پی از مبلغ اسنپ‌پی بیشتر می‌شود؛ ضریب را بررسی کنید');
      }
      snapp_part = S;
      goods_snapp_charge = S;
      goods_cash_charge = (net - S) + snapp_fee;
      snapp_charge = goods_snapp_charge + shipping_snapp;
      cash_charge = goods_cash_charge + shipping_cash;
      snapp_deposit = (S - snapp_fee) + shipping_snapp;
      customer_total = snapp_charge + cash_charge;
    } else if (method === 'snapp') {
      var goods_snapp = roundToStep(net * mult, step);
      goods_snapp_charge = goods_snapp;
      goods_cash_charge = 0;
      snapp_charge = goods_snapp + shipping_snapp;
      cash_charge = shipping_cash;
      snapp_deposit = net + shipping_snapp;
      customer_total = goods_snapp + shipping_fee;
      snapp_fee = 0;
    } else {
      goods_snapp_charge = 0;
      goods_cash_charge = net;
      snapp_charge = shipping_snapp;
      cash_charge = net + shipping_cash;
      snapp_deposit = shipping_snapp;
      customer_total = net + shipping_fee;
      snapp_fee = 0;
    }

    var goods_owe = baseSum - mahdi_discount;
    if (goods_owe < 0) {
      throw new Error('تخفیف بر عهده مغازه از مبلغ کالاهای مغازه بیشتر است');
    }
    var owe = goods_owe + shipping_fee;
    var h_share = hpSum - helia_discount;

    /* invariants, asserted here and in tests.html:
       every toman of the payout is owed either to the shop or kept by the
       page; what the customer pays splits exactly into Snapp + cash parts;
       what the page ends up holding (Snapp deposit + cash in hand) is the
       payout; for mixed, total = payout + snapp_fee; the goods charge plus
       the shipping charge is exactly the customer total. */
    var goods_charge = customer_total - shipping_fee;
    /* the partner split of the Snap-paid goods money (derived only) */
    var pSplit = splitClaim(owe, h_share, shipping_fee, shipping_snapp, snapp_deposit);
    var invariant_ok = (owe + h_share) === payout &&
                       (snapp_charge + cash_charge) === customer_total &&
                       (snapp_deposit + cash_charge) === payout &&
                       (goods_charge + shipping_fee) === customer_total &&
                       (method !== 'mixed' || customer_total === payout + snapp_fee) &&
                       pSplit.page_claim >= 0 && pSplit.page_debt >= 0 &&
                       (snapp_deposit - pSplit.page_claim + pSplit.page_debt) === owe;
    if (!invariant_ok) {
      throw new Error('خطای محاسباتی داخلی: پرداختی برابر با سهم‌ها نیست');
    }

    return {
      sub: sub,
      net: net,
      discount: discount,
      discount_bearer: bearer,
      mahdi_discount: mahdi_discount,
      helia_discount: helia_discount,
      shipping_method: ship,
      shipping_fee: shipping_fee,
      shipping_payment_method: shipPay,
      shipping_charge: shipping_fee,
      shipping_snapp_charge: shipping_snapp,
      shipping_cash_charge: shipping_cash,
      goods_charge: goods_charge,
      goods_snapp_charge: goods_snapp_charge,
      goods_cash_charge: goods_cash_charge,
      payment_method: method,
      goods_payment_method: method,
      snapp_multiplier: mult,
      rounding_step: step,
      customer_total: customer_total,
      payout: payout,
      owe: owe,
      h_share: h_share,
      snapp_part: snapp_part,
      cash_part: cash_part,
      remaining_goods: remaining_goods,
      expected_snapp: expected_snapp,
      fee_in_snapp: feeInSnapp,
      snapp_charge: snapp_charge,
      cash_charge: cash_charge,
      snapp_deposit: snapp_deposit,
      snapp_fee: snapp_fee,
      /* derived only: the partner split of the Snap-paid goods money */
      page_claim: pSplit.page_claim,
      page_debt: pSplit.page_debt,
      /* all four invariants above hold */
      invariant_ok: invariant_ok,
      /* warnings only — never block the user */
      negative_helia_share: h_share < 0,
      snapp_fee_clamped: snapp_fee_clamped
    };
  }

  /* Old rows have no shipping_payment_method; they behaved exactly like
     "shipping follows the goods method, mixed -> cash". */
  function shippingPaymentMethod(order) {
    if (!order) return 'cash';
    var v = order.shipping_payment_method;
    if (v === 'cash' || v === 'snapp') return v;
    var m = order.payment_method || order.method || 'cash';
    return m === 'mixed' ? 'cash' : m;
  }

  /* One definition of the Snapp settlement for a stored order row
     (Accounts / Reports / Invoice all use this): cash goods -> 0,
     snapp goods -> net, mixed -> snapp_part - snapp_fee; plus the shipping
     fee when the shipping itself is paid through Snapp. Prefers the stored
     snapp_deposit column when present. */
  function snappDeposit(order) {
    if (!order) return 0;
    if (order.snapp_deposit !== undefined && order.snapp_deposit !== null && order.snapp_deposit !== '') {
      var v = Math.floor(Number(order.snapp_deposit));
      if (isFinite(v)) return v;
    }
    var m = order.payment_method || order.method || 'cash';
    var shipFee = Math.floor(Number(order.shipping_fee) || 0);
    var shipSnap = shippingPaymentMethod(order) === 'snapp' ? shipFee : 0;
    if (m === 'mixed') {
      return Math.floor(Number(order.snapp_part) || 0) - Math.floor(Number(order.snapp_fee) || 0) + shipSnap;
    }
    if (m === 'snapp') {
      return Math.floor(Number(order.payout) || 0) - shipFee + shipSnap;
    }
    return shipSnap;
  }

  /* Core of the v6/v7 partner split (see the header): the Snap-paid goods
     money is divided between shop and page in the ratio of their
     entitlements. Exact BigInt half-up rounding — h_share * goodsSnap can
     exceed 2^53. Mirrored by public.order_page_claim / order_page_debt
     in setup.sql (migration 013); the two must agree. */
  function splitClaim(owe, hShare, shipFee, shipSnap, deposit) {
    var net = (owe - shipFee) + hShare;            /* goods value after discount */
    var goodsSnapp = deposit - shipSnap;           /* goods money that went to the shop via Snap Pay */
    var claim = 0;
    if (net > 0 && hShare > 0 && goodsSnapp > 0) {
      var num = BigInt(hShare) * BigInt(goodsSnapp);
      var den = BigInt(net);
      /* floor((2·num + den) / (2·den)) === round_half_up(num / den) */
      claim = Number((2n * num + den) / (2n * den));
      if (claim > goodsSnapp) claim = goodsSnapp;
    }
    return {
      goods_snapp: goodsSnapp,
      page_claim: claim,
      /* always >= 0 for every method/legacy path (verified by the sweep) */
      page_debt: owe - deposit + claim
    };
  }

  /* The partner split for a stored order row or a calcOrder result:
     { goods_snapp, page_claim, page_debt }. page_claim is the page's claim
     on the shop («طلب پیج از مغازه») — collectable once the order reaches
     `paid` (the UI/RPC gate on status; this stays money-only). */
  function pageSplit(order) {
    if (!order) return { goods_snapp: 0, page_claim: 0, page_debt: 0 };
    var shipFee = Math.max(0, Math.floor(Number(order.shipping_fee) || 0));
    var shipSnap = shippingPaymentMethod(order) === 'snapp' ? shipFee : 0;
    return splitClaim(
      Math.max(0, Math.floor(Number(order.owe) || 0)),
      Math.floor(Number(order.h_share) || 0),
      shipFee, shipSnap,
      Math.max(0, Math.floor(Number(snappDeposit(order)) || 0))
    );
  }

  /* Goods/shipping charge breakdown for a stored order row (card, invoice,
     CSV and reports use this). It is derived from the stored channel totals,
     so old rows work without any migration. */
  function orderSplit(order) {
    if (!order) {
      return {
        shipping_payment_method: 'cash', shipping_charge: 0,
        shipping_snapp_charge: 0, shipping_cash_charge: 0,
        goods_charge: 0, goods_snapp_charge: 0, goods_cash_charge: 0,
        snapp_charge: 0, cash_charge: 0
      };
    }
    var shipFee = Math.max(0, Math.floor(Number(order.shipping_fee) || 0));
    var total = Math.max(0, Math.floor(Number(order.total) || 0));
    var snap = Math.max(0, Math.floor(Number(order.snapp_charge) || 0));
    var cash = Math.max(0, Math.floor(Number(order.cash_charge) || 0));
    var shipPay = shippingPaymentMethod(order);
    var shipSnap = shipPay === 'snapp' ? shipFee : 0;
    var shipCash = shipFee - shipSnap;
    return {
      shipping_payment_method: shipPay,
      shipping_charge: shipFee,
      shipping_snapp_charge: shipSnap,
      shipping_cash_charge: shipCash,
      goods_charge: total - shipFee,
      goods_snapp_charge: Math.max(0, snap - shipSnap),
      goods_cash_charge: Math.max(0, cash - shipCash),
      snapp_charge: snap,
      cash_charge: cash
    };
  }

  /* Price a single unit for the product cards (no shipping, no discount). */
  function unitPrices(base, hp, settings) {
    var b = Math.floor(Number(base) || 0);
    var h = Math.floor(Number(hp) || 0);
    var unit_sum = b + h;
    var step = Math.floor(Number(settings.rounding_step) || 1);
    var mult = Number(settings.snapp_multiplier);
    if (!isFinite(mult)) mult = 1;
    return {
      base: b,
      hp: h,
      unit_sum: unit_sum,
      cash_price: unit_sum,
      snapp_price: roundToStep(unit_sum * mult, step)
    };
  }

  var Calc = {
    VERSION: 7,
    BEARERS: BEARERS,
    SHIPPING: SHIPPING,
    METHODS: METHODS,
    SHIPPING_PAYMENTS: SHIPPING_PAYMENTS,
    MIXED_ROUND: MIXED_ROUND,
    MIXED_TOLERANCE: MIXED_TOLERANCE,
    roundToStep: roundToStep,
    snappRound: snappRound,
    snappInverseRound: snappInverseRound,
    parseMoney: parseMoney,
    parseSnappPart: parseSnappPart,
    parseCashPart: parseCashPart,
    splitDiscount: splitDiscount,
    calcOrder: calcOrder,
    shippingPaymentMethod: shippingPaymentMethod,
    snappDeposit: snappDeposit,
    orderSplit: orderSplit,
    pageSplit: pageSplit,
    unitPrices: unitPrices
  };

  root.Calc = Calc;
  if (typeof module !== 'undefined' && module.exports) module.exports = Calc;
})(typeof window !== 'undefined' ? window : globalThis);
