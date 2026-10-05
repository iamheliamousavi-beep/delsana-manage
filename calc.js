/* calc.js — the single source of truth for all money calculations.
   Pure functions, integers only (toman). The only float allowed is the
   Snapp multiplier, which is applied and then rounded to rounding_step.
   The same formulas are implemented server-side in setup.sql (create_order)
   and mirrored by tests.html. */
(function (root) {
  'use strict';

  var BEARERS = ['helia', 'mahdi', 'split'];
  var SHIPPING = ['post', 'courier'];
  var METHODS = ['cash', 'snapp'];

  function roundToStep(x, step) {
    if (!isFinite(x)) throw new Error('roundToStep: not a number');
    var s = Math.floor(Math.abs(step)) > 0 ? Math.floor(Math.abs(step)) : 1;
    return Math.round(x / s) * s;
  }

  /* Split the discount between the two partners.
     helia pays it -> helia_discount = D; mahdi pays it -> mahdi_discount = D;
     split -> mahdi takes floor(D/2), helia takes the rest. */
  function splitDiscount(D, bearer) {
    var d = Math.floor(D);
    if (d < 0) throw new Error('discount must be >= 0');
    if (BEARERS.indexOf(bearer) === -1) throw new Error('unknown discount bearer: ' + bearer);
    if (bearer === 'helia') return { mahdi_discount: 0, helia_discount: d };
    if (bearer === 'mahdi') return { mahdi_discount: d, helia_discount: 0 };
    var md = Math.floor(d / 2);
    return { mahdi_discount: md, helia_discount: d - md };
  }

  /* inputs:
       items: [{ qty, cost, mp, hp, base }]   (snapshots)
       discount, discount_bearer
       shipping_method: 'post'|'courier'
       payment_method:  'cash'|'snapp'
       post_fee, snapp_multiplier, rounding_step      (settings/snapshot values)
     returns every derived amount as integers. */
  function calcOrder(inp) {
    if (!inp || !Array.isArray(inp.items)) throw new Error('calcOrder: items array required');

    var postFee = Math.floor(Number(inp.post_fee) || 0);
    var step = Math.floor(Number(inp.rounding_step) || 1);
    var mult = Number(inp.snapp_multiplier);
    if (!isFinite(mult)) mult = 1;
    var bearer = inp.discount_bearer || 'helia';
    var ship = inp.shipping_method || 'courier';
    var method = inp.payment_method || 'cash';

    if (BEARERS.indexOf(bearer) === -1) throw new Error('invalid discount_bearer');
    if (SHIPPING.indexOf(ship) === -1) throw new Error('invalid shipping_method');
    if (METHODS.indexOf(method) === -1) throw new Error('invalid payment_method');

    var sub = 0, baseSum = 0, hpSum = 0, mpSum = 0;
    for (var i = 0; i < inp.items.length; i++) {
      var it = inp.items[i];
      var q = Math.floor(Number(it.qty) || 0);
      var cost = Math.floor(Number(it.cost) || 0);
      var mp = Math.floor(Number(it.mp) || 0);
      var hp = Math.floor(Number(it.hp) || 0);
      var base = Math.floor(Number(it.base));
      if (!isFinite(base)) base = cost + mp;
      if (q <= 0) throw new Error('quantity must be >= 1');
      if (cost < 0 || mp < 0 || hp < 0) throw new Error('prices must be >= 0');
      sub += q * (cost + mp + hp);
      baseSum += q * base;
      hpSum += q * hp;
      mpSum += q * mp;
    }

    var discount = Math.floor(Number(inp.discount) || 0);
    if (discount < 0) throw new Error('discount must be >= 0');
    if (discount > sub) throw new Error('discount exceeds subtotal');

    var split = splitDiscount(discount, bearer);
    var mahdi_discount = split.mahdi_discount;
    var helia_discount = split.helia_discount;

    var shipping_fee = ship === 'post' ? postFee : 0;
    var net = sub - discount;

    var customer_total;
    if (method === 'snapp') {
      customer_total = roundToStep(net * mult, step) + shipping_fee;
    } else {
      customer_total = net + shipping_fee;
    }
    /* Snapp Pay settles the same amount a cash sale would produce. */
    var payout = net + shipping_fee;

    var owe = baseSum - mahdi_discount + shipping_fee;
    var h_share = hpSum - helia_discount;
    var m_profit = mpSum - mahdi_discount;

    /* invariant, asserted here and in tests.html: every toman of the payout is
       either owed to Mahdi or kept by Helia */
    if ((owe + h_share) !== payout) {
      throw new Error('calcOrder invariant violated: owe + h_share !== payout');
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
      payment_method: method,
      snapp_multiplier: mult,
      rounding_step: step,
      customer_total: customer_total,
      payout: payout,
      owe: owe,
      h_share: h_share,
      m_profit: m_profit,
      /* invariant: every toman of the payout is owed either to Mahdi or kept by Helia */
      invariant_ok: (owe + h_share) === payout,
      /* warnings only — never block the user */
      negative_mahdi_profit: m_profit < 0,
      negative_helia_share: h_share < 0
    };
  }

  /* Price a single unit for the product cards (no shipping, no discount). */
  function unitPrices(cost, mp, hp, settings) {
    var c = Math.floor(Number(cost) || 0);
    var m = Math.floor(Number(mp) || 0);
    var h = Math.floor(Number(hp) || 0);
    var base = c + m;
    var unit_sum = base + h;
    var step = Math.floor(Number(settings.rounding_step) || 1);
    var mult = Number(settings.snapp_multiplier);
    if (!isFinite(mult)) mult = 1;
    return {
      base: base,
      unit_sum: unit_sum,
      cash_price: unit_sum,
      snapp_price: roundToStep(unit_sum * mult, step)
    };
  }

  var Calc = {
    VERSION: 1,
    BEARERS: BEARERS,
    SHIPPING: SHIPPING,
    METHODS: METHODS,
    roundToStep: roundToStep,
    splitDiscount: splitDiscount,
    calcOrder: calcOrder,
    unitPrices: unitPrices
  };

  root.Calc = Calc;
  if (typeof module !== 'undefined' && module.exports) module.exports = Calc;
})(typeof window !== 'undefined' ? window : globalThis);
