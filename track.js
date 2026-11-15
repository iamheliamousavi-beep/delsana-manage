/* ==========================================================================
   track.js — the public order-tracking page ("مسیر سفارش").

   Customers look up their orders with MOBILE NUMBER + NAME. No admin code,
   no login, no libraries: one plain fetch POST to a single narrow RPC.
   Nothing about the entered phone/name is ever stored (no localStorage,
   no URL, no cookies, no analytics). All rendering through DOM APIs only.

   The visual language is the manager app's tokens (style.css) shaped into a
   "parcel journey": a dated stage timeline, item rows and a dashed postal
   ticket for the tracking code.
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
  var SVG_NS = 'http://www.w3.org/2000/svg';

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

  /* ------------------------------------------------------------- icons --- */
  /* Static, hand-authored path constants only — never server data. */
  var ICONS = {
    lock: '<rect x="4.5" y="10" width="15" height="10.5" rx="2.5"/>' +
          '<path d="M8.5 10V7.2a3.5 3.5 0 0 1 7 0V10"/>',
    bag: '<path d="M6.5 7.5h11l1 12.5h-13l1-12.5Z"/>' +
         '<path d="M9.5 7.5V6a2.5 2.5 0 0 1 5 0v1.5"/>',
    box: '<path d="M20.5 8.2 12 3.5 3.5 8.2v7.6L12 20.5l8.5-4.7V8.2Z"/>' +
         '<path d="m3.5 8.2 8.5 4.7 8.5-4.7"/><path d="M12 12.9v7.6"/>',
    truck: '<path d="M3 16.5V6.5h11v10"/><path d="M14 10h3.8l3.2 3.4v3.1h-7"/>' +
           '<circle cx="7.2" cy="18" r="1.7"/><circle cx="17.4" cy="18" r="1.7"/>',
    home: '<path d="m3.5 10.2 8.5-6.7 8.5 6.7V19a1.5 1.5 0 0 1-1.5 1.5h-4.5v-5.3H9.5v5.3H5A1.5 1.5 0 0 1 3.5 19v-8.8Z"/>',
    check: '<path d="m5 12.5 4.6 4.6L19 6.9"/>',
    copy: '<rect x="9" y="9" width="11" height="11" rx="2.5"/>' +
          '<path d="M5 15.5V5.5A1.5 1.5 0 0 1 6.5 4H16"/>',
    external: '<path d="M14 4h6v6"/><path d="m20 4-9.5 9.5"/>' +
              '<path d="M18.5 14.5V19a1.5 1.5 0 0 1-1.5 1.5H5A1.5 1.5 0 0 1 3.5 19V7A1.5 1.5 0 0 1 5 5.5h4.5"/>',
    warn: '<path d="M12 3.8 2.8 19.8h18.4L12 3.8Z"/><path d="M12 9.4v4.2"/>' +
          '<path d="M12 17h.01"/>',
    clock: '<circle cx="12" cy="12" r="8.6"/><path d="M12 7.5V12l3 2"/>',
    searchX: '<circle cx="11" cy="11" r="6.5"/><path d="m16 16 4.5 4.5"/>' +
             '<path d="m9 9 4 4"/><path d="m13 9-4 4"/>',
    wifiOff: '<path d="m3 3 18 18"/><path d="M8.6 15.6a5 5 0 0 1 6.8 0"/>' +
             '<path d="M5.2 12.2a10.4 10.4 0 0 1 3.1-1.8"/>' +
             '<path d="M15.7 10.4a10.4 10.4 0 0 1 3.1 1.8"/>' +
             '<path d="M2.5 8.6A15.5 15.5 0 0 1 7 6.4"/>' +
             '<path d="M17 6.4a15.5 15.5 0 0 1 4.5 2.2"/><path d="M12 19h.01"/>',
    refresh: '<path d="M20.5 12a8.5 8.5 0 1 1-2.49-6.01"/><path d="M20.5 4v5h-5"/>'
  };

  function icon(name, cls) {
    var s = document.createElementNS(SVG_NS, 'svg');
    s.setAttribute('viewBox', '0 0 24 24');
    s.setAttribute('fill', 'none');
    s.setAttribute('stroke', 'currentColor');
    s.setAttribute('stroke-width', '1.8');
    s.setAttribute('stroke-linecap', 'round');
    s.setAttribute('stroke-linejoin', 'round');
    s.setAttribute('aria-hidden', 'true');
    s.setAttribute('focusable', 'false');
    if (cls) s.setAttribute('class', cls);
    s.innerHTML = ICONS[name] || '';
    return s;
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
      submitBtn = $('track-submit'), submitLabel = submitBtn.querySelector('.track-submit-label'),
      errBox = $('track-error'), results = $('track-results'), resetBtn = $('track-reset'),
      guideEl = $('track-guide');
  var busy = false;
  var skeletonTimer = null;

  function setSubmitLabel(text) {
    if (submitLabel) submitLabel.textContent = text;
  }

  function showError(msg) {
    errBox.textContent = msg;
    errBox.hidden = false;
  }
  function clearError() { errBox.hidden = true; }

  /* --------------------------------------------------- loading skeleton -- */
  /* a stable skeleton instead of a flickering spinner; shown only if the
     lookup takes longer than 120ms, so fast answers never flash it */
  function skeletonCard() {
    var card = el('div', { class: 'card track-skeleton', 'aria-hidden': 'true' });
    card.appendChild(el('div', { class: 'sk sk-title' }));
    card.appendChild(el('div', { class: 'sk sk-line' }));
    for (var i = 0; i < 3; i++) {
      card.appendChild(el('div', { class: 'sk-step' },
        el('div', { class: 'sk sk-dot' }),
        el('div', { class: 'sk sk-grow' })));
    }
    card.appendChild(el('div', { class: 'sk sk-divider' }));
    card.appendChild(el('div', { class: 'sk sk-line w3' }));
    return card;
  }
  function skeletonHead() {
    return el('div', { class: 'track-skeleton-head', 'aria-hidden': 'true' },
      el('span', { class: 'sk sk-head-title' }),
      el('span', { class: 'sk sk-head-chip' }));
  }
  function showSkeleton() {
    if (!busy) return;
    results.setAttribute('aria-busy', 'true');
    results.textContent = '';
    results.appendChild(skeletonHead());
    results.appendChild(skeletonCard());
    results.appendChild(skeletonCard());
  }
  function clearSkeleton() {
    if (skeletonTimer) { clearTimeout(skeletonTimer); skeletonTimer = null; }
    results.removeAttribute('aria-busy');
  }

  /* ------------------------------------------------------------- render -- */
  function statusPill(stage) {
    var s = STAGE[stage] || STAGE.preparing;
    return el('span', { class: 'pill ' + s.pillClass + ' track-status-pill' },
      el('span', { class: 'track-pill-dot', 'aria-hidden': 'true' }),
      s.pill);
  }

  function stepTracker(order) {
    /* ثبت سفارش → آماده‌سازی → ارسال → تحویل; understandable without
       color: each marker carries a stage icon (✓ for completed stops) */
    var steps = [
      { label: 'ثبت سفارش', icon: 'bag', date: fmtDate(order.created_at) },
      { label: 'آماده‌سازی', icon: 'box', date: null },
      { label: 'ارسال', icon: 'truck', date: order.shipped_at ? fmtDate(order.shipped_at) : null },
      { label: 'تحویل', icon: 'home', date: order.delivered_at ? fmtDate(order.delivered_at) : null }
    ];
    var doneCount = { preparing: 1, shipped: 3, delivered: 4 }[order.stage] || 1;

    var list = el('ol', { class: 'track-steps', 'aria-label': 'مراحل سفارش' });
    steps.forEach(function (st, idx) {
      var state = idx < doneCount ? 'done' : (idx === doneCount ? 'current' : 'future');
      var mark = el('span', { class: 'track-step-mark' },
        icon(state === 'done' ? 'check' : st.icon));

      var when = st.date
        ? el('span', { class: 'track-step-date', text: st.date })
        : (state === 'current' ? el('span', { class: 'track-step-now', text: 'اکنون' }) : null);

      list.appendChild(el('li', { class: 'track-step ' + state },
        mark,
        el('div', { class: 'track-step-main' },
          el('span', { class: 'track-step-label', text: st.label }),
          when)));
    });
    return list;
  }

  function setCopyState(btn, done) {
    btn.textContent = '';
    btn.appendChild(icon(done ? 'check' : 'copy'));
    btn.appendChild(document.createTextNode(done ? 'کپی شد' : 'کپی کد رهگیری'));
    btn.disabled = done;
  }

  function shippingBlock(order) {
    if (order.stage !== 'shipped' && order.stage !== 'delivered') return null;

    if (order.shipping_method === 'courier') {
      return el('div', { class: 'track-ship-note' },
        icon('truck'),
        el('span', { text: 'سفارش شما با پیک ارسال شد.' }));
    }

    /* post */
    if (order.tracking) {
      var copyBtn = el('button', { class: 'btn small track-copy', type: 'button' },
        icon('copy'), el('span', { text: 'کپی کد رهگیری' }));

      copyBtn.addEventListener('click', function () {
        copyText(order.tracking, function () {
          setCopyState(copyBtn, true);
          setTimeout(function () { setCopyState(copyBtn, false); }, 2000);
        });
      });

      var codeBox = el('div', { class: 'track-ticket' },
        el('div', { class: 'track-ticket-head' },
          el('span', { class: 'track-ticket-title', text: 'کد رهگیری پست' }),
          el('span', { class: 'track-ticket-tag', text: 'پست' })),
        el('div', { class: 'track-ticket-body' },
          el('div', { class: 'track-code', dir: 'ltr', text: order.tracking }),
          copyBtn));

      /* the VPN notice sits directly next to the post-site link */
      var linkRow = el('div', { class: 'track-post-row' },
        el('a', {
          class: 'btn small track-post-link', href: 'https://tracking.post.ir',
          target: '_blank', rel: 'noopener noreferrer'
        }, icon('external'), el('span', { text: 'رهگیری در سایت پست' })),
        el('span', { class: 'track-vpn-note' },
          icon('warn'),
          el('span', { text: 'قبل از ورود به سایت پست، فیلترشکن (VPN) خود را خاموش کنید.' })));

      return el('div', { class: 'track-shipping' }, codeBox, linkRow);
    }

    return el('div', { class: 'track-ship-note' },
      icon('clock'),
      el('span', { text: 'کد رهگیری هنوز صادر نشده است. از صبر و شکیبایی شما ممنونیم.' }));
  }

  function orderCard(order, idx) {
    var stage = STAGE[order.stage] ? order.stage : 'preparing';
    var s = STAGE[stage];

    var card = el('article', { class: 'card track-order stage-' + stage });
    card.style.setProperty('--i', String(Math.min(idx, 5)));

    /* header: registration date + simplified status */
    card.appendChild(el('div', { class: 'track-order-head' },
      el('div', { class: 'track-order-when' },
        el('span', { class: 'track-label', text: 'تاریخ ثبت سفارش' }),
        el('strong', { class: 'track-order-date', text: fmtDate(order.created_at) })),
      statusPill(stage)));

    if (stage !== 'cancelled') card.appendChild(stepTracker(order));

    if (s.sentence) {
      card.appendChild(el('p', {
        class: 'track-sentence' + (stage === 'cancelled' ? ' track-sentence--danger' : ''),
        text: s.sentence
      }));
    }

    /* items */
    var items = order.items || [];
    if (items.length) {
      var itemsBox = el('div', { class: 'track-items' },
        el('div', { class: 'track-items-label' },
          el('span', { class: 'track-label', text: 'اقلام سفارش' }),
          el('span', { class: 'track-items-count',
                       text: toFaDigits(items.length) + ' قلم' })));

      items.forEach(function (it) {
        itemsBox.appendChild(el('div', { class: 'track-item' },
          el('span', { class: 'track-item-name', text: it.name || '' }),
          el('span', { class: 'track-item-qty', text: '× ' + toFaDigits(it.qty) })));
      });
      card.appendChild(itemsBox);
    }

    var ship = shippingBlock(order);
    if (ship) card.appendChild(ship);

    return card;
  }

  function resultHead(count) {
    return el('div', { class: 'track-result-head' },
      el('div', { class: 'track-result-title' },
        el('span', { class: 'track-eyebrow', text: 'نتیجه جست‌وجو' }),
        el('h2', { text: 'سفارش‌های شما' })),
      el('span', { class: 'chip track-count-chip', text: toFaDigits(count) + ' سفارش' }));
  }

  function messageCard(kind) {
    var config = {
      not_found: {
        icon: 'searchX',
        title: 'سفارشی پیدا نشد',
        text: MSG.not_found
      },
      rate_limited: {
        icon: 'clock',
        title: 'کمی صبر کنید',
        text: MSG.rate_limited
      },
      error: {
        icon: 'wifiOff',
        title: 'ارتباط برقرار نشد',
        text: MSG.error
      }
    }[kind] || null;

    if (!config) config = { icon: 'wifiOff', title: 'ارتباط برقرار نشد', text: MSG.error };

    var card = el('div', { class: 'card track-message track-message--' + kind },
      el('div', { class: 'track-message-icon', 'aria-hidden': 'true' }, icon(config.icon)),
      el('h3', { text: config.title }),
      el('p', { text: config.text }));

    if (kind === 'error') {
      card.appendChild(el('button', {
        class: 'btn small', type: 'button',
        onclick: function () { submitBtn.click(); }
      }, icon('refresh'), el('span', { text: 'تلاش دوباره' })));
    }

    return card;
  }

  function render(data) {
    clearSkeleton();
    results.textContent = '';   /* clear everything first */
    resetBtn.hidden = false;
    document.body.classList.add('has-results');

    if (data && data.status === 'ok') {
      var orders = data.orders || [];
      if (!orders.length) {
        results.appendChild(messageCard('not_found'));
        return;
      }
      results.appendChild(resultHead(orders.length));
      orders.forEach(function (o, i) { results.appendChild(orderCard(o, i)); });
      return;
    }
    if (data && (data.status === 'not_found' || data.status === 'rate_limited')) {
      results.appendChild(messageCard(data.status));
      return;
    }
    /* invalid (should not happen — client validates) and anything unknown */
    results.appendChild(messageCard('error'));
  }

  function renderNetworkError() {
    clearSkeleton();
    results.textContent = '';
    resetBtn.hidden = false;
    document.body.classList.add('has-results');
    results.appendChild(messageCard('error'));
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

    if (guideEl) guideEl.hidden = true;
    resetBtn.hidden = true;           /* no reset race while the lookup is in flight */

    busy = true;
    submitBtn.disabled = true;
    setSubmitLabel('در حال جست‌وجو…');
    skeletonTimer = setTimeout(showSkeleton, 120);

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
        clearSkeleton();
        submitBtn.disabled = false;
        setSubmitLabel('دیدن وضعیت سفارش');
      });
  });

  /* clear the inline error as soon as the customer edits a field */
  [phoneIn, nameIn].forEach(function (inp) {
    inp.addEventListener('input', function () { if (!errBox.hidden) clearError(); });
  });

  /* -------------------------------------------------------------- reset -- */
  resetBtn.addEventListener('click', function () {
    results.textContent = '';
    results.removeAttribute('aria-busy');
    document.body.classList.remove('has-results');
    phoneIn.value = '';
    nameIn.value = '';
    resetBtn.hidden = true;
    clearError();
    if (guideEl) guideEl.hidden = false;
    phoneIn.focus();
  });
})();
