/* ui.js — shared UI helpers: escaping, Persian number/date formatting,
   toasts, dialogs, validation and CSV export. No framework, no globals
   other than the `UI` object. */
(function (root) {
  'use strict';

  var FA_DIGITS = '۰۱۲۳۴۵۶۷۸۹';
  var AR_DIGITS = '٠١٢٣٤٥٦٧٨٩';

  /* ------------------------------------------------------------ escaping */
  function esc(v) {
    if (v === null || v === undefined) return '';
    return String(v).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  function qs(sel, ctx) { return (ctx || document).querySelector(sel); }
  function qsa(sel, ctx) { return Array.prototype.slice.call((ctx || document).querySelectorAll(sel)); }

  /* Create an element: el('div', {class:'x', onclick: fn}, child1, child2) */
  function el(tag, attrs) {
    var node = document.createElement(tag);
    if (attrs) {
      Object.keys(attrs).forEach(function (k) {
        var v = attrs[k];
        if (v === null || v === undefined || v === false) return;
        if (k === 'class') node.className = v;
        else if (k === 'html') node.innerHTML = v;           // trusted (static) HTML only
        else if (k === 'text') node.textContent = v;
        else if (k === 'dataset') Object.keys(v).forEach(function (d) { node.dataset[d] = v[d]; });
        else if (k.slice(0, 2) === 'on' && typeof v === 'function') node.addEventListener(k.slice(2), v);
        else if (k === 'value') node.value = v;
        else if (v === true) node.setAttribute(k, '');
        else node.setAttribute(k, v);
      });
    }
    appendKids(node, arguments, 2);
    return node;
  }

  /* children may be a Node, a string/number, an array of them, or nullish */
  function appendKids(parent, args, from) {
    for (var i = from; i < args.length; i++) {
      var c = args[i];
      if (c === null || c === undefined || c === false) continue;
      if (Array.isArray(c)) { appendKids(parent, c, 0); continue; }
      if (typeof c === 'string' || typeof c === 'number' || typeof c === 'boolean') {
        parent.appendChild(document.createTextNode(String(c)));
        continue;
      }
      parent.appendChild(c);
    }
  }

  /* --------------------------------------------------------------- digits */
  function toEnDigits(s) {
    return String(s === null || s === undefined ? '' : s)
      .replace(/[۰-۹]/g, function (d) { return String(FA_DIGITS.indexOf(d)); })
      .replace(/[٠-٩]/g, function (d) { return String(AR_DIGITS.indexOf(d)); });
  }

  function toFaDigits(s) {
    return String(s === null || s === undefined ? '' : s).replace(/[0-9]/g, function (d) {
      return FA_DIGITS[Number(d)];
    });
  }

  /* Dashes users type instead of a minus: U+2212 minus sign, U+2013 en
     dash, U+2014 em dash. Without this a price reduction typed as
     «۵۰۰۰−» would silently become a price increase. */
  var DASHES = /[\u2212\u2013\u2014]/g;

  /* Parse a user typed number: accepts Persian/Arabic digits, commas, spaces.
     Returns an integer or null when the input is not a usable number. */
  function parseInt10(s, allowNegative) {
    if (s === null || s === undefined) return null;
    var t = toEnDigits(s).replace(DASHES, '-').replace(/[,\s٫]/g, '').replace(/[^\d-]/g, '');
    if (t === '' || t === '-') return null;
    t = trailingMinus(t);
    var n = Number(t);
    if (!isFinite(n)) return null;
    n = Math.trunc(n);
    if (n < 0 && !allowNegative) return null;
    return n;
  }

  function parseFloat10(s) {
    if (s === null || s === undefined) return null;
    var t = toEnDigits(s).replace(DASHES, '-').replace(/[,\s]/g, '')
      .replace(/[٫]/g, '.').replace(/[^\d.\-]/g, '');
    if (t === '' || t === '-' || t === '.') return null;
    t = trailingMinus(t);
    var n = Number(t);
    return isFinite(n) ? n : null;
  }

  /* «۵۰۰۰−» means minus five thousand: move a lone trailing minus to the
     front so the value stays negative instead of being read as positive. */
  function trailingMinus(t) {
    if (t.length > 1 && t.charAt(t.length - 1) === '-' && t.indexOf('-') === t.length - 1) {
      return '-' + t.slice(0, -1);
    }
    return t;
  }

  var moneyFmt = null;
  function fmtMoney(n) {
    var v = Math.trunc(Number(n) || 0);
    if (!moneyFmt) {
      try { moneyFmt = new Intl.NumberFormat('fa-IR'); }
      catch (e) { moneyFmt = new Intl.NumberFormat('en-US'); }
    }
    return moneyFmt.format(v);
  }

  /* money + unit, for compact labels */
  function money(n) { return fmtMoney(n) + ' تومان'; }

  /* ---------------------------------------------------------------- dates */
  var jalaliDT = null, jalaliD = null;
  function fmtDateTime(iso) {
    if (!iso) return '—';
    try {
      if (!jalaliDT) {
        jalaliDT = new Intl.DateTimeFormat('fa-IR-u-ca-persian', {
          year: 'numeric', month: '2-digit', day: '2-digit',
          hour: '2-digit', minute: '2-digit', hour12: false
        });
      }
      return jalaliDT.format(new Date(iso));
    } catch (e) { return new Date(iso).toLocaleString(); }
  }
  function fmtDate(iso) {
    if (!iso) return '—';
    try {
      if (!jalaliD) {
        jalaliD = new Intl.DateTimeFormat('fa-IR-u-ca-persian', {
          year: 'numeric', month: '2-digit', day: '2-digit'
        });
      }
      return jalaliD.format(new Date(iso));
    } catch (e) { return new Date(iso).toLocaleDateString(); }
  }

  function startOfDay(d) { var x = new Date(d); x.setHours(0, 0, 0, 0); return x; }
  function addDays(d, n) { var x = new Date(d); x.setDate(x.getDate() + n); return x; }
  function toLocalInputDate(d) {
    var x = new Date(d);
    var m = String(x.getMonth() + 1).padStart(2, '0');
    var day = String(x.getDate()).padStart(2, '0');
    return x.getFullYear() + '-' + m + '-' + day;
  }

  /* --------------------------------------------------------------- toasts */
  function toast(msg, type, ms) {
    var host = document.getElementById('toasts');
    if (!host) return;
    var t = el('div', { class: 'toast ' + (type || ''), text: msg });
    host.appendChild(t);
    var life = ms || (type === 'err' ? 5200 : 2600);
    setTimeout(function () {
      t.style.transition = 'opacity .3s, transform .3s';
      t.style.opacity = '0';
      t.style.transform = 'translateY(8px)';
      setTimeout(function () { if (t.parentNode) t.parentNode.removeChild(t); }, 320);
    }, life);
  }

  /* --------------------------------------------------------------- modals */
  /* modal({title, body, actions:[{label, value, cls, primary}]}) -> Promise */
  function modal(opts) {
    return new Promise(function (resolve) {
      var root = document.getElementById('modal-root');
      root.innerHTML = '';

      var bodyNode;
      if (opts.body instanceof Node) bodyNode = opts.body;
      else bodyNode = el('div', { class: 'modal-body', html: opts.body || '' }); // caller escapes

      var actions = opts.actions || [{ label: 'باشه', value: true, primary: true }];
      var actionRow = el('div', { class: 'modal-actions' });
      actions.forEach(function (a) {
        actionRow.appendChild(el('button', {
          type: 'button',
          class: 'btn ' + (a.cls || (a.primary ? 'primary' : '')),
          text: a.label,
          onclick: function () { finish(a.value); }
        }));
      });

      var box = el('div', { class: 'modal', role: 'dialog', 'aria-modal': 'true' },
        el('h3', { text: opts.title || '' }),
        bodyNode,
        actionRow);

      var back = el('div', {
        class: 'modal-backdrop',
        onclick: function (e) { if (e.target === back && opts.dismissible !== false) finish(null); }
      }, box);

      root.appendChild(back);

      function finish(v) {
        document.removeEventListener('keydown', keyHandler);
        back.style.opacity = '0';
        back.style.transition = 'opacity .12s';
        setTimeout(function () { root.innerHTML = ''; }, 120);
        resolve(v);
      }
      function keyHandler(e) {
        if (e.key === 'Escape' && opts.dismissible !== false) { e.preventDefault(); finish(null); }
      }
      document.addEventListener('keydown', keyHandler);

      var focusable = box.querySelector('input, textarea, select, button');
      if (focusable) setTimeout(function () { focusable.focus(); }, 60);
    });
  }

  function confirmDialog(msg, opts) {
    opts = opts || {};
    return modal({
      title: opts.title || 'تأیید عملیات',
      body: '<p style="margin:0">' + esc(msg) + '</p>' +
            (opts.detail ? '<p class="muted" style="margin:.5em 0 0;white-space:pre-line">' + esc(opts.detail) + '</p>' : ''),
      actions: [
        { label: opts.cancelLabel || 'انصراف', value: false },
        { label: opts.okLabel || 'تأیید', value: true, cls: opts.danger ? 'danger' : 'primary', primary: true }
      ]
    }).then(function (v) { return v === true; });
  }

  /* promptDialog({title, label, value, multiline, placeholder, required})
     -> Promise<string|null>  (null = cancelled) */
  function promptDialog(opts) {
    opts = opts || {};
    var input = opts.multiline
      ? el('textarea', { placeholder: opts.placeholder || '', rows: 3 })
      : el('input', { type: opts.type || 'text', placeholder: opts.placeholder || '', value: opts.value || '' });
    if (!opts.multiline && opts.inputmode) input.setAttribute('inputmode', opts.inputmode);
    if (opts.dir) input.setAttribute('dir', opts.dir);

    var wrap = el('div', {},
      el('div', { class: 'field' },
        el('label', { text: opts.label || '' }), input));

    return modal({
      title: opts.title || 'ورود اطلاعات',
      body: wrap,
      actions: [
        { label: 'انصراف', value: null },
        { label: opts.okLabel || 'ثبت', value: '__ok__', primary: true }
      ]
    }).then(function (v) {
      if (v !== '__ok__') return null;
      var val = String(input.value || '').trim();
      if (opts.required && !val) {
        toast(opts.requiredMessage || 'این فیلد اجباری است', 'warn');
        var retry = {};
        Object.keys(opts).forEach(function (k) { retry[k] = opts[k]; });
        retry.value = '';
        return promptDialog(retry);
      }
      if (opts.maxlength && val.length > opts.maxlength) {
        toast('متن واردشده بلندتر از حد مجاز است', 'warn');
        var retry2 = {};
        Object.keys(opts).forEach(function (k) { retry2[k] = opts[k]; });
        retry2.value = val;
        return promptDialog(retry2);
      }
      return val;
    });
  }

  /* --------------------------------------------------------------- buttons */
  function withBusy(btn, fn) {
    if (!btn || btn.disabled) return Promise.resolve();
    var html = btn.innerHTML;
    btn.disabled = true;
    btn.classList.add('busy');
    btn.innerHTML = '<span class="inline-spinner" aria-hidden="true"></span>';
    var done = function () {
      btn.disabled = false;
      btn.classList.remove('busy');
      btn.innerHTML = html;
    };
    return Promise.resolve()
      .then(fn)
      .then(function (r) { done(); return r; },
            function (e) { done(); throw e; });
  }

  function skeletons(host, n) {
    host.innerHTML = '';
    for (var i = 0; i < (n || 3); i++) host.appendChild(el('div', { class: 'skeleton' }));
  }

  function emptyState(title, sub) {
    return el('div', { class: 'empty' },
      el('strong', { text: title }),
      sub ? el('span', { text: sub }) : null);
  }

  /* ------------------------------------------------------------ validation */
  function normalizePostal(v) { return toEnDigits(v).replace(/[^\d]/g, ''); }
  function isValidPostal(v) { return /^[0-9]{10}$/.test(normalizePostal(v)); }
  function normalizePhone(v) { return toEnDigits(v).replace(/[^\d+]/g, ''); }
  function isValidPhone(v) { var d = normalizePhone(v).replace(/\D/g, ''); return d.length >= 10 && d.length <= 15; }

  /* --------------------------------------------------------------- labels */
  var STATUS = {
    'new': 'جدید',
    'awaiting_snapp': 'در انتظار اسنپ‌پی',
    'paid': 'پرداخت شده',
    'settled': 'تسویه شده',
    'shipped': 'ارسال شده',
    'delivered': 'تحویل شده',
    'cancelled': 'لغو شده'
  };
  var STATUS_FLOW = {
    'new': ['paid', 'cancelled'],
    'awaiting_snapp': ['paid', 'cancelled'],
    'paid': ['settled', 'cancelled'],
    'settled': ['shipped', 'cancelled'],
    'shipped': ['delivered'],
    'delivered': [],
    'cancelled': []
  };
  var ACTION_LABEL = {
    'paid': 'دریافت پول',
    'settled': 'تسویه با مغازه',
    'shipped': 'ارسال شد',
    'delivered': 'تحویل شد',
    'cancelled': 'لغو سفارش'
  };

  function statusLabel(s) { return STATUS[s] || s; }
  function statusPill(s) {
    return el('span', { class: 'pill st-' + s, text: STATUS[s] || s });
  }
  function nextActions(order) {
    return (STATUS_FLOW[order.status] || []).map(function (s) {
      return {
        status: s,
        label: s === 'paid' && order.method === 'cash' ? 'پرداخت شد' : ACTION_LABEL[s],
        cls: s === 'cancelled' ? 'danger' : (s === 'shipped' || s === 'delivered' || s === 'settled' || s === 'paid' ? 'primary' : ''),
        danger: s === 'cancelled'
      };
    });
  }

  /* Display names only — the internal identities (roles `mahdi` / `helia`,
     RPC names, keys) never change. */
  var PARTY_LABEL = { mahdi: 'مغازه', helia: 'پیج' };
  function partyLabel(role) { return PARTY_LABEL[role] || role; }

  var BEARER_LABEL = { helia: 'پیج', mahdi: 'مغازه', split: 'نصف‌نصف' };
  function bearerLabel(b) { return BEARER_LABEL[b] || b; }
  function shippingLabel(s) { return s === 'post' ? 'پست' : 'پیک'; }
  function methodLabel(m) { return m === 'snapp' ? 'اسنپ‌پی' : 'نقدی/کارت'; }

  /* ------------------------------------------------------------------ CSV */
  function csvCell(v) {
    var s = v === null || v === undefined ? '' : String(v);
    if (/^[=+@\-\t\r]/.test(s) && !/^-?\d+(\.\d+)?$/.test(s)) s = "'" + s;
    return '"' + s.replace(/"/g, '""') + '"';
  }
  function downloadCSV(filename, rows) {
    var csv = rows.map(function (r) { return r.map(csvCell).join(','); }).join('\r\n');
    var blob = new Blob(['\uFEFF' + csv], { type: 'text/csv;charset=utf-8;' });
    var url = URL.createObjectURL(blob);
    var a = el('a', { href: url, download: filename });
    document.body.appendChild(a);
    a.click();
    setTimeout(function () { URL.revokeObjectURL(url); a.remove(); }, 400);
  }

  /* --------------------------------------------------------------- errors */
  function errMessage(e) {
    var raw = '';
    if (!e) return 'خطای ناشناخته';
    if (typeof e === 'string') raw = e;
    else raw = e.message || e.error_description || e.error || e.code || '';
    raw = String(raw);
    var map = [
      ['Invalid login credentials', 'ایمیل یا رمز عبور اشتباه است'],
      ['Email not confirmed', 'ایمیل هنوز تأیید نشده است'],
      ['User already registered', 'کاربری با این ایمیل ثبت شده است'],
      ['Password should be at least', 'رمز عبور باید حداقل ۶ کاراکتر باشد'],
      ['Failed to fetch', 'اتصال به سرور برقرار نشد؛ اینترنت را بررسی کنید'],
      ['NetworkError', 'اتصال به سرور برقرار نشد؛ اینترنت را بررسی کنید'],
      ['JWT expired', 'نشست شما منقضی شده؛ دوباره وارد شوید'],
      ['row-level security', 'شما دسترسی لازم برای این عملیات را ندارید'],
      ['duplicate key', 'این رکورد قبلاً ثبت شده است'],
      ['violates check', 'مقدار واردشده مجاز نیست'],
      ['permission denied', 'شما دسترسی لازم برای این عملیات را ندارید'],
      ['does not exist', 'داده موردنظر پیدا نشد؛ صفحه را تازه‌سازی کنید'],
      ['aborted', 'درخواست ناتمام ماند؛ دوباره تلاش کنید'],
      ['onAuthStateChange', 'خطا در وضعیت ورود']
    ];
    for (var i = 0; i < map.length; i++) {
      if (raw.toLowerCase().indexOf(map[i][0].toLowerCase()) !== -1) return map[i][1];
    }
    if (!raw) return 'خطای ناشناخته؛ دوباره تلاش کنید';
    return raw;
  }

  function debounce(fn, ms) {
    var t = null;
    return function () {
      var args = arguments, self = this;
      clearTimeout(t);
      t = setTimeout(function () { fn.apply(self, args); }, ms || 250);
    };
  }

  root.UI = {
    esc: esc, qs: qs, qsa: qsa, el: el,
    toEnDigits: toEnDigits, toFaDigits: toFaDigits,
    parseInt10: parseInt10, parseFloat10: parseFloat10,
    fmtMoney: fmtMoney, money: money,
    fmtDateTime: fmtDateTime, fmtDate: fmtDate,
    startOfDay: startOfDay, addDays: addDays, toLocalInputDate: toLocalInputDate,
    toast: toast, modal: modal, confirm: confirmDialog, prompt: promptDialog,
    withBusy: withBusy, skeletons: skeletons, emptyState: emptyState,
    normalizePostal: normalizePostal, isValidPostal: isValidPostal,
    normalizePhone: normalizePhone, isValidPhone: isValidPhone,
    statusLabel: statusLabel, statusPill: statusPill, nextActions: nextActions,
    STATUS: STATUS, STATUS_FLOW: STATUS_FLOW, ACTION_LABEL: ACTION_LABEL,
    PARTY_LABEL: PARTY_LABEL, partyLabel: partyLabel,
    BEARER_LABEL: BEARER_LABEL,
    bearerLabel: bearerLabel, shippingLabel: shippingLabel, methodLabel: methodLabel,
    downloadCSV: downloadCSV, errMessage: errMessage, debounce: debounce
  };
})(window);
