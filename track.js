/* ==========================================================================
   track.js — the public order-tracking page (prompt-6 v2).

   Customers look up their orders with MOBILE NUMBER + NAME. No admin code,
   no login, no libraries: one plain fetch POST to a single narrow RPC.
   Nothing about the entered phone/name is ever stored (no localStorage,
   no URL, no cookies, no analytics). All rendering through DOM APIs only.
   ========================================================================== */

(function () {
  'use strict';

  /* -------------------------------------------------------------- CONFIG -- */
  /* the two PUBLIC values (same as app.js CONFIG) — safe to expose */
  var TRACK_CONFIG = {
    supabaseUrl: 'https://jmeloxuzdhabbszkthgt.supabase.co',
    supabaseAnonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImptZWxveHV6ZGhhYmJzemt0aGd0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTEyOTIwNDYsImV4cCI6MjEwNjg2ODA0Nn0.0y6-W_ACDcGw4DHwtle7u6oO4zDnw5hRpZODvo4xkO0',
    instagramUsername: 'delsana.co'
  };

  /* --------------------------------------------------------- helpers ----- */
  var FA_DIGITS = '۰۱۲۳۴۵۶۷۸۹';
  var AR_DIGITS = '٠١٢٣٤٥٦٧٨٩';

  /* copied from ui.js (this page must not load the admin scripts) */
  function toEnDigits(s) {
    return String(s === null || s === undefined ? '' : s)
      .replace(/[۰-۹]/g, function (d) { return String(FA_DIGITS.indexOf(d)); })
      .replace(/[٠-٩]/g, function (d) { return String(AR_DIGITS.indexOf(d)); });
  }

  function normalizePhone(v) { return toEnDigits(v).replace(/[^\d+]/g, ''); }

  function toFaDigits(s) {
    return String(s === null || s === undefined ? '' : s).replace(/[0-9]/g, function (d) {
      return FA_DIGITS[Number(d)];
    });
  }

  function $(id) { return document.getElementById(id); }

  function el(tag, attrs) {
    var node = document.createElement(tag);
    if (attrs) {
      Object.keys(attrs).forEach(function (k) {
        var v = attrs[k];
        if (v === null || v === undefined || v === false) return;
        if (k === 'class') node.className = v;
        else if (k === 'text') node.textContent = v;
        else if (k === 'dataset') Object.keys(v).forEach(function (d) { node.dataset[d] = v[d]; });
        else if (k.slice(0, 2) === 'on' && typeof v === 'function') node.addEventListener(k.slice(2), v);
        else if (k === 'value') node.value = v;
        else if (v === true) node.setAttribute(k, '');
        else node.setAttribute(k, v);
      });
    }
    for (var i = 2; i < arguments.length; i++) {
      var c = arguments[i];
      if (c === null || c === undefined || c === false) continue;
      if (Array.isArray(c)) {
        c.forEach(function (x) { if (x) node.appendChild(x); });
        continue;
      }
      node.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
    }
    return node;
  }

  /* clipboard with an execCommand fallback (Instagram in-app browsers) */
  function copyText(text, done) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, function () { legacyCopy(text, done); });
    } else {
      legacyCopy(text, done);
    }
  }
  function legacyCopy(text, done) {
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand('copy'); } catch (e) { /* best effort */ }
    document.body.removeChild(ta);
    if (done) done();
  }

  /* Jalali calendar, Persian digits, Tehran time */
  var dtf = null;
  try {
    dtf = new Intl.DateTimeFormat('fa-IR-u-ca-persian', {
      timeZone: 'Asia/Tehran',
      year: 'numeric', month: 'long', day: 'numeric',
      hour: '2-digit', minute: '2-digit'
    });
  } catch (e) { /* very old engines */ }
  function fmtDate(iso) {
    var d = new Date(iso);
    if (isNaN(d.getTime())) return '';
    try {
      return dtf ? dtf.format(d) : d.toLocaleString('fa-IR');
    } catch (e) {
      return d.toLocaleString('fa-IR');
    }
  }

  /* ------------------------------------------------------------- texts --- */
  var STAGE = {
    preparing: { pill: 'در حال آماده‌سازی', pillClass: 'warn',
                 sentence: 'سفارش شما در حال آماده‌سازی است.' },
    shipped:   { pill: 'ارسال شد', pillClass: 'st-shipped', sentence: null },
    delivered: { pill: 'تحویل شد', pillClass: 'st-delivered', sentence: null },
    cancelled: { pill: 'لغو شده', pillClass: 'st-cancelled',
                 sentence: 'برای اطلاعات بیشتر در دایرکت پیام دهید.' }
  };

  var MSG = {
    not_found: 'سفارشی با این مشخصات پیدا نشد. شماره موبایل و نام را ' +
               'همان‌طور که هنگام ثبت سفارش اعلام کرده‌اید وارد کنید، ' +
               'یا در دایرکت پیام دهید.',
    rate_limited: 'تعداد تلاش‌ها زیاد بود. لطفاً چند دقیقه دیگر دوباره ' +
                  'امتحان کنید یا در دایرکت پیام دهید.',
    error: 'در دریافت اطلاعات مشکلی پیش آمد. دوباره تلاش کنید، یا اگر ' +
           'اینترنت ندارید، بعد از وصل شدن دوباره امتحان کنید.'
  };

  /* -------------------------------------------------------------- state -- */
  var form = $('track-form'), phoneIn = $('track-phone'), nameIn = $('track-name'),
      submitBtn = $('track-submit'), errBox = $('track-error'),
      results = $('track-results'), resetBtn = $('track-reset');
  var busy = false;

  function showError(msg) {
    errBox.textContent = msg;
    errBox.hidden = false;
  }
  function clearError() { errBox.hidden = true; }

  /* ------------------------------------------------------------- render -- */
  function messageCard(text) {
    return el('div', { class: 'card track-message', text: text });
  }

  function statusPill(stage) {
    var s = STAGE[stage] || STAGE.preparing;
    return el('span', { class: 'pill ' + s.pillClass, text: s.pill });
  }

  function stepTracker(order) {
    /* ثبت سفارش → آماده‌سازی → ارسال → تحویل; understandable without
       color: ✓ done / ● current / ○ future, plus dates when known */
    var steps = [
      { label: 'ثبت سفارش', date: fmtDate(order.created_at) },
      { label: 'آماده‌سازی', date: null },
      { label: 'ارسال', date: order.shipped_at ? fmtDate(order.shipped_at) : null },
      { label: 'تحویل', date: order.delivered_at ? fmtDate(order.delivered_at) : null }
    ];
    var doneCount = { preparing: 1, shipped: 3, delivered: 4 }[order.stage] || 1;

    var list = el('ol', { class: 'track-steps' });
    steps.forEach(function (st, idx) {
      var state = idx < doneCount ? 'done' : (idx === doneCount ? 'current' : 'future');
      var mark = state === 'done' ? '✓' : (state === 'current' ? '●' : '○');
      var item = el('li', { class: 'track-step ' + state },
        el('span', { class: 'track-step-mark', 'aria-hidden': 'true', text: mark }),
        el('span', { class: 'track-step-label', text: st.label }));
      if (st.date) item.appendChild(el('span', { class: 'track-step-date', text: st.date }));
      list.appendChild(item);
    });
    return list;
  }

  function shippingBlock(order) {
    if (order.stage !== 'shipped' && order.stage !== 'delivered') return null;

    if (order.shipping_method === 'courier') {
      return el('p', { class: 'track-shipping', text: 'سفارش شما با پیک ارسال شد.' });
    }

    /* post */
    if (order.tracking) {
      var codeBox = el('div', { class: 'track-code-box' },
        el('div', { class: 'track-code', dir: 'ltr', text: order.tracking }),
        el('button', {
          class: 'btn small', type: 'button', text: 'کپی کد رهگیری',
          onclick: function () {
            copyText(order.tracking, function () {
              var b = codeBox.querySelector('button');
              if (b) { b.textContent = 'کپی شد'; b.disabled = true;
                       setTimeout(function () { b.textContent = 'کپی کد رهگیری';
                                                b.disabled = false; }, 2000); }
            });
          }
        }));

      /* the VPN notice sits directly next to the post-site link */
      var linkRow = el('div', { class: 'track-post-row' },
        el('a', {
          class: 'btn small', href: 'https://tracking.post.ir',
          target: '_blank', rel: 'noopener noreferrer',
          text: 'رهگیری در سایت پست'
        }),
        el('span', { class: 'alert warn track-vpn-note',
                     text: 'قبل از ورود به سایت پست، فیلترشکن (VPN) خود را خاموش کنید.' }));

      return el('div', { class: 'track-shipping' }, codeBox, linkRow);
    }

    return el('p', { class: 'track-shipping',
      text: 'کد رهگیری هنوز صادر نشده است. از صبر و شکیبایی شما ممنونیم.' });
  }

  function orderCard(order) {
    var s = STAGE[order.stage] || STAGE.preparing;

    var card = el('article', { class: 'card track-order' });

    var head = el('div', { class: 'track-order-head' },
      el('div', {},
        el('span', { class: 'track-label', text: 'تاریخ ثبت' }),
        el('div', { class: 'track-date', text: fmtDate(order.created_at) })),
      statusPill(order.stage));
    card.appendChild(head);

    var items = el('div', { class: 'track-items' },
      el('span', { class: 'track-label', text: 'اقلام سفارش' }));
    (order.items || []).forEach(function (it) {
      items.appendChild(el('div', { class: 'track-item',
        text: (it.name || '') + ' × ' + toFaDigits(it.qty) }));
    });
    card.appendChild(items);

    if (s.sentence) card.appendChild(el('p', { class: 'track-sentence', text: s.sentence }));

    var ship = shippingBlock(order);
    if (ship) card.appendChild(ship);

    if (order.stage !== 'cancelled') card.appendChild(stepTracker(order));

    return card;
  }

  function render(data) {
    results.textContent = '';   /* clear everything first */
    resetBtn.hidden = false;

    if (data && data.status === 'ok') {
      var orders = data.orders || [];
      results.appendChild(el('p', { class: 'track-count',
        text: toFaDigits(orders.length) + ' سفارش پیدا شد' }));
      orders.forEach(function (o) { results.appendChild(orderCard(o)); });
      return;
    }
    if (data && (data.status === 'not_found' || data.status === 'rate_limited')) {
      results.appendChild(messageCard(MSG[data.status]));
      return;
    }
    /* invalid (should not happen — client validates) and anything unknown */
    results.appendChild(messageCard(MSG.error));
  }

  function renderNetworkError() {
    results.textContent = '';
    resetBtn.hidden = false;
    results.appendChild(messageCard(MSG.error));
  }

  /* ------------------------------------------------------------- submit -- */
  form.addEventListener('submit', function (ev) {
    ev.preventDefault();
    if (busy) return;                       /* double submits are ignored */
    clearError();

    var phone = normalizePhone(phoneIn.value);
    var digits = phone.replace(/[^0-9]/g, '');
    var name = nameIn.value.trim();

    if (digits.length < 10) {
      showError('شماره موبایل باید حداقل ۱۰ رقم باشد.');
      phoneIn.focus();
      return;
    }
    if (name.length < 2) {
      showError('نام باید حداقل ۲ حرف باشد.');
      nameIn.focus();
      return;
    }

    busy = true;
    submitBtn.disabled = true;
    submitBtn.textContent = 'در حال جست‌وجو…';

    fetch(TRACK_CONFIG.supabaseUrl + '/rest/v1/rpc/track_orders', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'apikey': TRACK_CONFIG.supabaseAnonKey,
        'Authorization': 'Bearer ' + TRACK_CONFIG.supabaseAnonKey
      },
      body: JSON.stringify({ p_phone: phone, p_name: name })
    })
      .then(function (res) {
        if (!res.ok) throw new Error('http ' + res.status);
        return res.json();
      })
      .then(render)
      .catch(renderNetworkError)
      .then(function () {
        busy = false;
        submitBtn.disabled = false;
        submitBtn.textContent = 'جست‌وجو';
      });
  });

  /* -------------------------------------------------------------- reset -- */
  resetBtn.addEventListener('click', function () {
    results.textContent = '';
    phoneIn.value = '';
    nameIn.value = '';
    resetBtn.hidden = true;
    clearError();
    phoneIn.focus();
  });
})();
