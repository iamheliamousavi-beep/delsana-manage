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
   warning for tiny S) is paid in cash. */
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
  /* Parse the raw Snapp-part input (single source of truth for the rule in
     the new-order form AND the tests): Persian/Arabic digits, thousand
     separators and a trailing-dash minus are accepted; a fractional value
     (1.5, ۵٫۵) is an error, never silently truncated. Throws SNAPP_PART_MSG. */
  function parseSnappPart(text) {
    if (text === null || text === undefined) throw new Error(SNAPP_PART_MSG);
    var t = toEnDigits(text).replace(/[\u2212\u2013\u2014]/g, '-').replace(/[\s,٬]/g, '');
    var m = /^(-?)(\d+)(?:[\.\u066B](\d+))?$/.exec(t);
    if (!m) throw new Error(SNAPP_PART_MSG);
    if (m[3] && !/^0+$/.test(m[3])) throw new Error(SNAPP_PART_MSG);
    var v = Number((m[1] || '') + m[2]);
    if (!isFinite(v) || v < 1 || v > MAX_SAFE) throw new Error(SNAPP_PART_MSG);
    return v;
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
       snapp_part: the Snapp side S (mixed only; cash/snapp must send null/0)
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
    if (method === 'mixed') {
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
    var invariant_ok = (owe + h_share) === payout &&
                       (snapp_charge + cash_charge) === customer_total &&
                       (snapp_deposit + cash_charge) === payout &&
                       (goods_charge + shipping_fee) === customer_total &&
                       (method !== 'mixed' || customer_total === payout + snapp_fee);
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
      snapp_charge: snapp_charge,
      cash_charge: cash_charge,
      snapp_deposit: snapp_deposit,
      snapp_fee: snapp_fee,
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
    VERSION: 5,
    BEARERS: BEARERS,
    SHIPPING: SHIPPING,
    METHODS: METHODS,
    SHIPPING_PAYMENTS: SHIPPING_PAYMENTS,
    roundToStep: roundToStep,
    snappRound: snappRound,
    parseSnappPart: parseSnappPart,
    splitDiscount: splitDiscount,
    calcOrder: calcOrder,
    shippingPaymentMethod: shippingPaymentMethod,
    snappDeposit: snappDeposit,
    orderSplit: orderSplit,
    unitPrices: unitPrices
  };

  root.Calc = Calc;
  if (typeof module !== 'undefined' && module.exports) module.exports = Calc;
})(typeof window !== 'undefined' ? window : globalThis);
