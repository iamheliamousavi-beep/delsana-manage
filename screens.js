/* screens.js — all six screens: products, new order, orders, accounts,
   reports, settings.  Every screen exposes render() (build once + paint)
   and refresh() (repaint after data/realtime changes). */
var Screens = (function () {
  'use strict';

  var $ = UI.qs, $$ = UI.qsa, el = UI.el;

  /* ============================================================== helpers */

  function host(id) { return document.getElementById(id); }

  function shell(id, key, build) {
    var h = host(id);
    if (h.dataset.shell === key) return false;
    h.innerHTML = '';
    h.dataset.shell = key;
    build(h);
    return true;
  }

  function productById(id) {
    for (var i = 0; i < App.products.length; i++) {
      if (App.products[i].id === id) return App.products[i];
    }
    return null;
  }

  /* price info for one unit. Mahdi sees real cost/mp; Helia only knows
     base_price (cost+mp) and hp — m_profit is never shown to her. */
  function priceInfo(p) {
    var c = App.isMahdi && App.costs[p.id] ? App.costs[p.id] : null;
    var base = c ? (c.cost + c.mp) : Number(p.base_price) || 0;
    return {
      cost: c ? c.cost : 0,
      mp: c ? c.mp : base,
      base: base,
      hp: Number(p.hp) || 0,
      unit_sum: base + (Number(p.hp) || 0)
    };
  }

  function snappPrice(unitSum) {
    return Calc.roundToStep(unitSum * App.settings.snapp_multiplier, App.settings.rounding_step);
  }

  function isFocusedIn(node) {
    var a = document.activeElement;
    if (!a || a === document.body) return false;
    return node.contains(a) && /INPUT|SELECT|TEXTAREA/.test(a.tagName);
  }

  function moneyCell(k, v, cls) {
    return el('div', { class: 'money-cell ' + (cls || '') },
      el('span', { class: 'k', text: k }),
      el('span', { class: 'v', text: v }));
  }

  function showErr(e) { UI.toast(UI.errMessage(e), 'err'); }

  /* Re-render the orders list, but first let go of any tracking input the
     user still has focused — otherwise the focus guard would hide our own
     update (the input lives inside #ord-list). */
  function repaintOrders() {
    var list = $('#ord-list');
    var a = document.activeElement;
    if (list && a && list.contains && list.contains(a) && /INPUT|SELECT|TEXTAREA/.test(a.tagName)) a.blur();
    Screens.orders.refresh();
  }

  /* ============================================================== PRODUCTS */
  var products = {
    q: '',
    selected: {},

    render: function () {
      shell('view-products', 'v1', build);
      this.refresh();
    },

    refresh: function () {
      var list = $('#prod-list');
      if (!list) return;
      if (isFocusedIn(list)) return;

      var q = products.q.trim().toLowerCase();
      var rows = App.products.filter(function (p) {
        if (!q) return true;
        return String(p.name).toLowerCase().indexOf(q) !== -1;
      });
      rows.sort(function (a, b) {
        if (!!a.archived !== !!b.archived) return a.archived ? 1 : -1;
        return String(a.name).localeCompare(String(b.name), 'fa');
      });

      list.innerHTML = '';
      if (!rows.length) {
        list.appendChild(UI.emptyState('محصولی پیدا نشد',
          q ? 'عبارت دیگری را جستجو کنید' : (App.isMahdi ? 'با دکمه «محصول جدید» اولین محصول را بسازید' : '')));
      } else {
        rows.forEach(function (p) { list.appendChild(productCard(p)); });
      }
      updateBulkBar();
      var addBtn = $('#prod-add');
      if (addBtn) addBtn.hidden = !App.isMahdi;
      var bulkBtn = $('#prod-bulk');
      if (bulkBtn) bulkBtn.hidden = !App.isMahdi;
    }
  };

  function build(h) {
    h.appendChild(el('div', { class: 'view-head' },
      el('h2', { text: 'محصولات' }),
      el('span', { class: 'spacer' }),
      el('button', {
        class: 'btn small', id: 'prod-bulk', type: 'button', text: 'به‌روزرسانی قیمت گروهی',
        hidden: !App.isMahdi,
        onclick: function () { toggleBulkMode(); }
      }),
      el('button', {
        class: 'btn primary small', id: 'prod-add', type: 'button', text: '＋ محصول جدید',
        hidden: !App.isMahdi,
        onclick: addProductDialog
      })
    ));

    h.appendChild(el('div', { class: 'field' },
      el('input', {
        type: 'search', id: 'prod-search', placeholder: 'جستجوی نام محصول…',
        oninput: UI.debounce(function (e) { products.q = e.target.value; products.refresh(); }, 180)
      })
    ));

    h.appendChild(el('div', { id: 'prod-list' }));
    h.appendChild(el('div', { id: 'prod-bulkbar' }));
  }

  var bulkMode = false;

  function toggleBulkMode() {
    bulkMode = !bulkMode;
    if (!bulkMode) products.selected = {};
    products.refresh();
  }

  function updateBulkBar() {
    var hostEl = $('#prod-bulkbar');
    if (!hostEl) return;
    hostEl.innerHTML = '';
    if (!bulkMode || !App.isMahdi) return;

    var ids = Object.keys(products.selected);
    var bar = el('div', { class: 'bulk-bar' });
    bar.appendChild(el('div', { class: 'row wrap' },
      el('strong', { text: UI.toFaDigits(ids.length) + ' محصول انتخاب شده' }),
      el('select', { id: 'bulk-mode', class: 'grow', 'aria-label': 'نوع تغییر' },
        el('option', { value: 'percent', text: 'درصدی' }),
        el('option', { value: 'fixed', text: 'مبلغ ثابت' })),
      el('input', {
        type: 'text', id: 'bulk-value', class: 'grow', inputmode: 'decimal',
        placeholder: 'مقدار (مثلاً ۱۰ یا ۵۰۰۰−)', 'aria-label': 'مقدار تغییر'
      }),
      el('button', {
        class: 'btn primary small', type: 'button', text: 'اعمال روی قیمت خرید',
        onclick: applyBulk
      }),
      el('button', {
        class: 'btn small', type: 'button', text: 'پایان',
        onclick: function () { bulkMode = false; products.selected = {}; products.refresh(); }
      })
    ));
    bar.appendChild(el('p', {
      class: 'hint', style: 'margin:6px 0 0',
      text: 'درصدی: قیمت خرید × (۱ + مقدار ÷ ۱۰۰) — مبلغ ثابت: قیمت خرید + مقدار. مقادیر منفی مجازند.'
    }));
    hostEl.appendChild(bar);
  }

  async function applyBulk() {
    var ids = Object.keys(products.selected);
    if (!ids.length) { UI.toast('ابتدا چند محصول را انتخاب کنید', 'warn'); return; }
    var mode = $('#bulk-mode').value;
    var value = UI.parseFloat10($('#bulk-value').value);
    if (value === null) { UI.toast('مقدار تغییر را وارد کنید', 'warn'); return; }
    var label = mode === 'percent' ? (UI.toFaDigits(value) + ' درصد') : (UI.money(value));
    var yes = await UI.confirm(
      'قیمت خرید ' + UI.toFaDigits(ids.length) + ' محصول با تغییر ' + label + ' به‌روز شود؟',
      { title: 'به‌روزرسانی گروهی قیمت', okLabel: 'اعمال' });
    if (!yes) return;
    try {
      var n = await DB.bulkCostUpdate(ids, mode, value);
      UI.toast('قیمت ' + UI.toFaDigits(n || 0) + ' محصول به‌روز شد', 'ok');
      products.selected = {};
      bulkMode = false;
      products.refresh();
    } catch (e) { showErr(e); }
  }

  function productCard(p) {
    var pi = priceInfo(p);
    var low = !p.archived && p.stock <= 2;
    var card = el('div', { class: 'card product' });

    var head = el('div', { class: 'product-head' },
      el('div', {},
        el('div', { class: 'product-name', text: p.name + (p.archived ? ' ' : '') }),
        p.archived ? el('span', { class: 'pill muted archived-tag', text: 'بایگانی‌شده' }) : null,
        el('div', {
          class: 'product-stock' + (low ? ' low' : ''),
          text: 'موجودی: ' + UI.toFaDigits(p.stock) + (low ? ' — موجودی کم!' : '')
        })
      )
    );

    if (App.isMahdi && bulkMode) {
      head.appendChild(el('input', {
        type: 'checkbox',
        style: 'width:22px;height:22px;accent-color:var(--brand)',
        'aria-label': 'انتخاب ' + p.name,
        checked: !!products.selected[p.id],
        onchange: function (e) {
          if (e.target.checked) products.selected[p.id] = true;
          else delete products.selected[p.id];
          updateBulkBar();
        }
      }));
    }
    card.appendChild(head);

    var prices = el('div', { class: 'price-grid' },
      el('div', { class: 'price-box hero' },
        el('span', { class: 'k', text: 'قیمت نقدی' }),
        el('span', { class: 'v', text: UI.fmtMoney(pi.unit_sum) })),
      el('div', { class: 'price-box' },
        el('span', { class: 'k', text: 'قیمت اسنپ‌پی' }),
        el('span', { class: 'v', text: UI.fmtMoney(snappPrice(pi.unit_sum)) })),
      App.isMahdi
        ? el('div', { class: 'price-box' },
            el('span', { class: 'k', text: 'قیمت خرید (مهدی)' }),
            el('span', { class: 'v', text: UI.fmtMoney(pi.cost) }))
        : el('div', { class: 'price-box' },
            el('span', { class: 'k', text: 'قیمت از مهدی' }),
            el('span', { class: 'v', text: UI.fmtMoney(pi.base) })),
      App.isMahdi
        ? el('div', { class: 'price-box' },
            el('span', { class: 'k', text: 'سود مهدی' }),
            el('span', { class: 'v', text: UI.fmtMoney(pi.mp) }))
        : null,
      el('div', { class: 'price-box' },
        el('span', { class: 'k', text: 'سود هلیا' }),
        el('span', { class: 'v', text: UI.fmtMoney(pi.hp) }))
    );
    card.appendChild(prices);

    var saveBtn = el('button', { class: 'btn primary small', type: 'button', text: 'ذخیره' });
    var edit = el('div', { class: 'edit-grid' });

    if (App.isMahdi) {
      var nameIn = el('input', { type: 'text', value: p.name, 'aria-label': 'نام محصول' });
      var stockIn = el('input', { type: 'text', inputmode: 'numeric', value: String(p.stock), 'aria-label': 'موجودی' });
      var costIn = el('input', { type: 'text', inputmode: 'numeric', value: String(pi.cost), 'aria-label': 'قیمت خرید' });
      var mpIn = el('input', { type: 'text', inputmode: 'numeric', value: String(pi.mp), 'aria-label': 'سود مهدی' });
      edit.appendChild(fieldWrap('نام', nameIn));
      edit.appendChild(fieldWrap('موجودی', stockIn));
      edit.appendChild(fieldWrap('قیمت خرید', costIn));
      edit.appendChild(fieldWrap('سود مهدی', mpIn));

      saveBtn.addEventListener('click', async function () {
        var name = nameIn.value.trim();
        var stock = UI.parseInt10(stockIn.value);
        var cost = UI.parseInt10(costIn.value);
        var mp = UI.parseInt10(mpIn.value);
        if (!name) { UI.toast('نام محصول اجباری است', 'warn'); return; }
        if (stock === null || cost === null || mp === null) {
          UI.toast('موجودی و قیمت‌ها باید عدد صحیح باشند', 'warn'); return;
        }
        await UI.withBusy(saveBtn, async function () {
          try {
            var changes = [];
            if (name !== p.name || stock !== p.stock) {
              changes.push(DB.updateProduct({ id: p.id, name: name, stock: stock, archived: p.archived }));
            }
            if (cost !== pi.cost || mp !== pi.mp) changes.push(DB.setCost(p.id, cost, mp));
            await Promise.all(changes);
            UI.toast('ذخیره شد', 'ok', 1600);
            Screens.products.refresh();
          } catch (e) { showErr(e); throw e; }
        });
      });
    } else {
      var hpIn = el('input', { type: 'text', inputmode: 'numeric', value: String(pi.hp), 'aria-label': 'سود هلیا' });
      edit.appendChild(fieldWrap('سود هلیا (هر واحد)', hpIn));
      saveBtn.addEventListener('click', async function () {
        var hp = UI.parseInt10(hpIn.value);
        if (hp === null) { UI.toast('سود باید عدد صحیح باشد', 'warn'); return; }
        await UI.withBusy(saveBtn, async function () {
          try {
            await DB.setHp(p.id, hp);
            UI.toast('سود شما ذخیره شد', 'ok', 1600);
            Screens.products.refresh();
          } catch (e) { showErr(e); throw e; }
        });
      });
    }

    var actions = el('div', { class: 'row wrap', style: 'margin-top:10px' }, saveBtn);
    if (App.isMahdi) {
      actions.appendChild(el('button', {
        class: 'btn small', type: 'button',
        text: p.archived ? 'بازگردانی از بایگانی' : 'بایگانی',
        onclick: async function () {
          var wasArchived = !!p.archived;
          if (!wasArchived) {
            var yes = await UI.confirm('محصول «' + p.name + '» بایگانی شود؟ دیگر در سفارش جدید نمایش داده نمی‌شود.',
              { title: 'بایگانی محصول', okLabel: 'بایگانی', danger: true });
            if (!yes) return;
          }
          try {
            await DB.updateProduct({ id: p.id, name: p.name, stock: p.stock, archived: !wasArchived });
            UI.toast(wasArchived ? 'بازگردانده شد' : 'بایگانی شد', 'ok', 1600);
            Screens.products.refresh();
          } catch (e) { showErr(e); }
        }
      }));
    }

    card.appendChild(edit);
    card.appendChild(actions);
    return card;
  }

  function fieldWrap(label, input) {
    return el('div', { class: 'field' }, el('label', { text: label }), input);
  }

  async function addProductDialog() {
    var name = el('input', { type: 'text', placeholder: 'مثلاً کرم مرطوب‌کننده' });
    var stock = el('input', { type: 'text', inputmode: 'numeric', placeholder: '۰' });
    var cost = el('input', { type: 'text', inputmode: 'numeric', placeholder: '۴۰۰۰۰۰' });
    var mp = el('input', { type: 'text', inputmode: 'numeric', placeholder: '۱۰۰۰۰۰' });
    var hp = el('input', { type: 'text', inputmode: 'numeric', placeholder: '۱۵۰۰۰۰' });

    var body = el('div', {},
      fieldWrap('نام محصول', name),
      fieldWrap('موجودی اولیه', stock),
      fieldWrap('قیمت خرید از بازار (تومان)', cost),
      fieldWrap('سود مهدی (تومان)', mp),
      fieldWrap('سود هلیا (تومان)', hp),
      el('p', { class: 'hint', text: 'قیمت نقدی = قیمت خرید + سود مهدی + سود هلیا' })
    );

    var v = await UI.modal({
      title: 'محصول جدید',
      body: body,
      actions: [{ label: 'انصراف', value: null }, { label: 'ثبت محصول', value: '__ok__', primary: true }]
    });
    if (v !== '__ok__') return;

    var p = {
      name: name.value.trim(),
      stock: UI.parseInt10(stock.value),
      cost: UI.parseInt10(cost.value),
      mp: UI.parseInt10(mp.value),
      hp: UI.parseInt10(hp.value)
    };
    if (!p.name) { UI.toast('نام محصول اجباری است', 'warn'); return; }
    if (p.stock === null || p.cost === null || p.mp === null || p.hp === null) {
      UI.toast('موجودی و همه قیمت‌ها باید عدد صحیح باشند', 'warn'); return;
    }
    try {
      await DB.addProduct(p);
      UI.toast('محصول ساخته شد', 'ok');
      Screens.products.refresh();
    } catch (e) { showErr(e); }
  }

  /* ============================================================ NEW ORDER */
  var neworder = {
    cart: [],           /* [{product_id, qty}] */
    pickerQ: '',
    built: false,

    render: function () {
      shell('view-neworder', 'v1', buildNewOrder);
      this.refresh();
    },

    refresh: function () {
      if (!this.built && $('#no-lines')) this.built = true;
      renderLines();
      renderPicker();
      updateSummary();
    }
  };

  function buildNewOrder(h) {
    h.appendChild(el('div', { class: 'view-head' },
      el('h2', { text: 'سفارش جدید' }),
      el('span', { class: 'spacer' }),
      el('button', {
        class: 'btn small', type: 'button', text: 'پاک‌کردن فرم',
        onclick: async function () {
          if (!neworder.cart.length && !$('#no-customer').value) return;
          var yes = await UI.confirm('فرم پاک شود؟', { title: 'پاک‌کردن فرم', okLabel: 'پاک شود', danger: true });
          if (yes) resetOrderForm();
        }
      })
    ));

    var grid = el('div', { class: 'grid cols' });

    /* -------- left column: products + customer + shipping ------------- */
    var left = el('div', {});

    left.appendChild(el('div', { class: 'card' },
      el('div', { class: 'card-title' }, el('h3', { text: 'کالاها' })),
      el('div', { class: 'field' },
        el('input', {
          type: 'search', id: 'no-search', placeholder: 'جستجوی محصول…',
          oninput: UI.debounce(function (e) { neworder.pickerQ = e.target.value; renderPicker(); }, 160)
        })),
      el('div', { class: 'picker', id: 'no-picker' }),
      el('div', { id: 'no-lines', class: 'lines', style: 'margin-top:10px' })
    ));

    left.appendChild(el('div', { class: 'card' },
      el('div', { class: 'card-title' }, el('h3', { text: 'اطلاعات مشتری' })),
      el('div', { class: 'field' },
        el('label', { for: 'no-customer', text: 'نام مشتری' }),
        el('input', { type: 'text', id: 'no-customer', autocomplete: 'off', placeholder: 'نام و خانوادگی' })),
      el('div', { class: 'field' },
        el('label', { for: 'no-phone', text: 'شماره تماس' }),
        el('input', { type: 'tel', id: 'no-phone', inputmode: 'tel', dir: 'ltr', placeholder: '09121234567' })),
      el('div', { class: 'field' },
        el('label', { for: 'no-address', text: 'آدرس' }),
        el('textarea', { id: 'no-address', placeholder: 'استان، شهر، خیابان، پلاک' })),
      el('div', { class: 'field' },
        el('label', { for: 'no-postal', text: 'کد پستی (۱۰ رقم)' }),
        el('input', { type: 'text', id: 'no-postal', inputmode: 'numeric', dir: 'ltr', maxlength: '14', placeholder: '1234567890' }),
        el('p', { class: 'hint', id: 'no-postal-hint', text: 'ارقام فارسی هم پذیرفته می‌شود' }))
    ));

    var shipSeg = segmented('no-ship', [
      { value: 'post', label: 'پست پیشتاز' },
      { value: 'courier', label: 'پیک شهری' }
    ], 'post');
    var paySeg = segmented('no-pay', [
      { value: 'cash', label: 'نقدی / کارت' },
      { value: 'snapp', label: 'اسنپ‌پی' }
    ], 'cash');

    var shipCard = el('div', { class: 'card' },
      el('div', { class: 'card-title' }, el('h3', { text: 'ارسال و پرداخت' })),
      el('div', { class: 'field' }, el('label', { text: 'روش ارسال' }), shipSeg),
      el('div', { class: 'field' }, el('label', { text: 'روش پرداخت' }), paySeg),
      el('div', { class: 'field', id: 'no-mult-wrap', hidden: true },
        el('label', { for: 'no-mult', text: 'ضریب اسنپ‌پی (اختیاری)' }),
        el('input', { type: 'text', id: 'no-mult', inputmode: 'decimal', placeholder: String(App.settings.snapp_multiplier) }),
        el('p', { class: 'hint', text: 'پیش‌فرض از تنظیمات خوانده می‌شود؛ سفارش همین مقدار را ذخیره می‌کند' })),
      el('div', { class: 'field', id: 'no-status-wrap', hidden: false },
        el('label', { for: 'no-status', text: 'وضعیت اولیه سفارش' }),
        el('select', { id: 'no-status' },
          el('option', { value: 'new', text: 'جدید (پول هنوز نرسیده)' }),
          el('option', { value: 'paid', text: 'پرداخت شده (پول در حساب هلیا)' }))),
      el('div', { class: 'field' },
        el('label', { for: 'no-discount', text: 'تخفیف (تومان)' }),
        el('input', { type: 'text', id: 'no-discount', inputmode: 'numeric', placeholder: '۰' })),
      el('div', { class: 'field', id: 'no-bearer-wrap', hidden: true },
        el('label', { text: 'تخفیف بر عهده' }),
        segmented('no-bearer', [
          { value: 'helia', label: 'هلیا' },
          { value: 'mahdi', label: 'مهدی' },
          { value: 'split', label: 'نصف‌نصف' }
        ], 'helia')),
      el('div', { class: 'field' },
        el('label', { for: 'no-note', text: 'یادداشت (اختیاری)' }),
        el('textarea', { id: 'no-note', placeholder: 'مثلاً: مشتری ساعت ۶ عصر تماس می‌گیرد' }))
    );
    left.appendChild(shipCard);

    /* -------- right column: summary ------------------------------------ */
    var right = el('div', {});
    var summaryCard = el('div', { class: 'card pad-lg' },
      el('div', { class: 'card-title' }, el('h3', { text: 'خلاصه سفارش' })),
      el('div', { id: 'no-warnings' }),
      el('div', { class: 'summary', id: 'no-summary' })
    );
    right.appendChild(summaryCard);

    var saveBtn = el('button', {
      class: 'btn primary block', id: 'no-save', type: 'button', text: 'ثبت سفارش',
      style: 'min-height:52px;font-size:1.02rem',
      onclick: saveOrder
    });
    right.appendChild(saveBtn);
    right.appendChild(el('p', {
      class: 'hint', style: 'text-align:center',
      text: 'موجودی پس از ثبت کم می‌شود و مبلغ‌ها در سرور محاسبه می‌شوند'
    }));

    grid.appendChild(left);
    grid.appendChild(right);
    h.appendChild(grid);

    /* live updates */
    h.addEventListener('input', function (e) {
      if (e.target.id === 'no-search') return;
      updateSummary();
    });
    h.addEventListener('change', function () { updateSummary(); });
    h.addEventListener('input', function (e) {
      if (e.target.id === 'no-postal') {
        var hint = $('#no-postal-hint');
        hint.textContent = UI.isValidPostal(e.target.value)
          ? 'کد پستی معتبر است ✓'
          : 'ارقام فارسی هم پذیرفته می‌شود';
        hint.style.color = UI.isValidPostal(e.target.value) ? 'var(--ok)' : 'var(--muted)';
      }
    });

    neworder.built = true;
  }

  function segmented(id, options, checked) {
    var wrap = el('div', { class: 'segmented', id: id, role: 'radiogroup' });
    options.forEach(function (o, i) {
      var input = el('input', {
        type: 'radio', name: id, value: o.value, id: id + '-' + o.value,
        checked: o.value === checked || (checked === null && i === 0)
      });
      var label = el('label', { for: id + '-s' + i, text: o.label });
      input.id = id + '-s' + i;
      label.setAttribute('for', input.id);
      if (input.checked) label.classList.add('on');
      input.addEventListener('change', function () {
        UI.qsa('label', wrap).forEach(function (l) { l.classList.remove('on'); });
        label.classList.add('on');
        wrap.dispatchEvent(new Event('change', { bubbles: true }));
      });
      wrap.appendChild(input);
      wrap.appendChild(label);
    });
    return wrap;
  }

  function radioValue(id) {
    var checked = document.querySelector('#' + id + ' input:checked');
    return checked ? checked.value : null;
  }
  function setRadio(id, value) {
    UI.qsa('#' + id + ' input').forEach(function (i) {
      i.checked = i.value === value;
      var lab = document.querySelector('label[for="' + i.id + '"]');
      if (lab) lab.classList.toggle('on', i.checked);
    });
  }

  function renderPicker() {
    var box = $('#no-picker');
    if (!box) return;
    var q = neworder.pickerQ.trim().toLowerCase();
    box.innerHTML = '';
    var rows = App.products.filter(function (p) {
      if (p.archived) return false;
      if (!q) return true;
      return String(p.name).toLowerCase().indexOf(q) !== -1;
    }).slice(0, 40);

    if (!rows.length) {
      box.appendChild(el('div', { class: 'empty', style: 'border:0', text: 'محصولی پیدا نشد' }));
      return;
    }
    rows.forEach(function (p) {
      var pi = priceInfo(p);
      var inCart = neworder.cart.some(function (c) { return c.product_id === p.id; });
      box.appendChild(el('button', {
        type: 'button', class: 'picker-item',
        onclick: function () { addToCart(p); }
      },
        el('span', {},
          el('span', { class: 'pi-name', text: p.name }),
          el('span', { class: 'pi-meta', style: 'display:block',
            text: 'موجودی ' + UI.toFaDigits(p.stock) + ' · ' + UI.fmtMoney(pi.unit_sum) + ' تومان' })),
        el('span', { class: 'pill ' + (p.stock <= 0 ? 'danger' : (p.stock <= 2 ? 'muted' : 'brand')),
          text: inCart ? 'در سبد ✓' : (p.stock <= 0 ? 'ناموجود' : UI.toFaDigits(p.stock)) })
      ));
    });
  }

  function addToCart(p) {
    var line = neworder.cart.filter(function (c) { return c.product_id === p.id; })[0];
    if (line) line.qty += 1;
    else neworder.cart.push({ product_id: p.id, qty: 1 });
    UI.toast('«' + p.name + '» اضافه شد', 'ok', 1300);
    neworder.refresh();
  }

  function renderLines() {
    var hostEl = $('#no-lines');
    if (!hostEl) return;
    hostEl.innerHTML = '';
    if (!neworder.cart.length) {
      hostEl.appendChild(el('p', { class: 'hint', text: 'هنوز کالایی انتخاب نشده است' }));
      return;
    }
    neworder.cart.forEach(function (line) {
      var p = productById(line.product_id);
      if (!p) return;
      var pi = priceInfo(p);
      var over = line.qty > p.stock;
      var qtyInput = el('input', {
        type: 'text', inputmode: 'numeric', class: 'qty-input', value: String(line.qty),
        'aria-label': 'تعداد ' + p.name,
        onchange: function (e) {
          var v = UI.parseInt10(e.target.value);
          if (v === null || v < 1) v = 1;
          line.qty = v;
          renderLines();
          updateSummary();
        }
      });
      hostEl.appendChild(el('div', { class: 'line-item' + (over ? ' over' : '') },
        el('div', { class: 'grow' },
          el('div', { class: 'name', text: p.name }),
          el('div', {
            class: 'meta',
            text: UI.fmtMoney(pi.unit_sum) + ' × هر واحد' +
                  (over ? ' — بیشتر از موجودی (' + UI.toFaDigits(p.stock) + ')' : '')
          })),
        qtyInput,
        el('span', { class: 'line-total', text: UI.fmtMoney(line.qty * pi.unit_sum) }),
        el('button', {
          class: 'btn tiny', type: 'button', text: '✕', title: 'حذف', 'aria-label': 'حذف ' + p.name,
          onclick: function () {
            neworder.cart = neworder.cart.filter(function (c) { return c !== line; });
            renderLines(); renderPicker(); updateSummary();
          }
        })
      ));
    });
  }

  function orderCalc() {
    var items = [];
    for (var i = 0; i < neworder.cart.length; i++) {
      var line = neworder.cart[i];
      var p = productById(line.product_id);
      if (!p) continue;
      var pi = priceInfo(p);
      items.push({ qty: line.qty, cost: pi.cost, mp: pi.mp, hp: pi.hp, base: pi.base });
    }
    if (!items.length) return null;
    var discount = UI.parseInt10($('#no-discount') ? $('#no-discount').value : '0') || 0;
    var method = radioValue('no-pay') || 'cash';
    var shipping = radioValue('no-ship') || 'post';
    var bearer = radioValue('no-bearer') || 'helia';
    var mult = null;
    if (method === 'snapp') {
      var raw = UI.parseFloat10($('#no-mult') ? $('#no-mult').value : '');
      mult = raw === null ? App.settings.snapp_multiplier : raw;
    }
    try {
      return Calc.calcOrder({
        items: items,
        discount: discount,
        discount_bearer: bearer,
        shipping_method: shipping,
        payment_method: method,
        post_fee: App.settings.post_fee,
        snapp_multiplier: mult === null ? App.settings.snapp_multiplier : mult,
        rounding_step: App.settings.rounding_step
      });
    } catch (e) { return { error: e.message }; }
  }

  function updateSummary() {
    var wrap = $('#no-summary');
    if (!wrap) return;

    var multWrap = $('#no-mult-wrap');
    var statusWrap = $('#no-status-wrap');
    var bearerWrap = $('#no-bearer-wrap');
    var method = radioValue('no-pay') || 'cash';
    if (multWrap) multWrap.hidden = method !== 'snapp';
    if (statusWrap) statusWrap.hidden = method !== 'cash';
    var discount = UI.parseInt10($('#no-discount') ? $('#no-discount').value : '0') || 0;
    if (bearerWrap) bearerWrap.hidden = !(discount > 0);

    var warn = $('#no-warnings');
    warn.innerHTML = '';

    var r = orderCalc();
    wrap.innerHTML = '';
    if (!r) {
      wrap.appendChild(el('p', { class: 'hint', text: 'برای دیدن خلاصه، کالایی انتخاب کنید' }));
      return;
    }
    if (r.error) {
      warn.appendChild(el('div', { class: 'alert danger', text: r.error }));
      return;
    }

    /* non blocking warnings */
    neworder.cart.forEach(function (line) {
      var p = productById(line.product_id);
      if (p && line.qty > p.stock) {
        warn.appendChild(el('div', {
          class: 'alert warn',
          text: 'تعداد «' + p.name + '» بیشتر از موجودی است (موجودی: ' + UI.toFaDigits(p.stock) + ')'
        }));
      }
    });
    if (r.negative_helia_share) {
      warn.appendChild(el('div', { class: 'alert warn', text: 'سود هلیا منفی می‌شود؛ تخفیف را کم کنید' }));
    }
    if (App.isMahdi && r.negative_mahdi_profit) {
      warn.appendChild(el('div', { class: 'alert warn', text: 'سود مهدی منفی می‌شود؛ تخفیف را کم کنید' }));
    }
    if (!r.invariant_ok) {
      warn.appendChild(el('div', { class: 'alert danger', text: 'خطای محاسباتی داخلی؛ لطفاً صفحه را تازه‌سازی کنید' }));
    }

    var rows = [
      ['مبلغ کالاها', UI.fmtMoney(r.sub), ''],
      ['تخفیف' + (discount > 0 ? ' (' + UI.bearerLabel(r.discount_bearer) + ')' : ''), '− ' + UI.fmtMoney(r.discount), ''],
      ['هزینه ارسال (' + UI.shippingLabel(r.shipping_method) + ')', UI.fmtMoney(r.shipping_fee), ''],
      [method === 'snapp' ? 'مبلغ اسنپ‌پی شامل کارمزد' : 'مبلغ قابل پرداخت مشتری',
        UI.fmtMoney(r.customer_total), 'total'],
      ['پرداختی به مهدی', UI.fmtMoney(r.owe), ''],
      ['سهم هلیا', UI.fmtMoney(r.h_share), '']
    ];
    if (App.isMahdi) rows.push(['سود مهدی', UI.fmtMoney(r.m_profit), '']);
    if (method === 'snapp') rows.push(['تسویه اسنپ‌پی (نقدی‌مانند)', UI.fmtMoney(r.payout), '']);

    rows.forEach(function (row) {
      wrap.appendChild(el('div', { class: 'sum-row ' + (row[2] || '') },
        el('span', { class: 'k', text: row[0] }),
        el('span', { class: 'v', text: row[1] })));
    });
  }

  function resetOrderForm() {
    neworder.cart = [];
    neworder.pickerQ = '';
    ['no-customer', 'no-phone', 'no-address', 'no-postal', 'no-discount', 'no-note', 'no-mult'].forEach(function (id) {
      var n = document.getElementById(id);
      if (n) n.value = '';
    });
    var s = $('#no-search'); if (s) s.value = '';
    setRadio('no-ship', 'post');
    setRadio('no-pay', 'cash');
    setRadio('no-bearer', 'helia');
    var st = $('#no-status'); if (st) st.value = 'new';
    var hint = $('#no-postal-hint');
    if (hint) { hint.textContent = 'ارقام فارسی هم پذیرفته می‌شود'; hint.style.color = ''; }
    neworder.refresh();
  }

  async function saveOrder() {
    var customer = ($('#no-customer').value || '').trim();
    var phone = ($('#no-phone').value || '').trim();
    var address = ($('#no-address').value || '').trim();
    var postal = ($('#no-postal').value || '').trim();
    var note = ($('#no-note').value || '').trim();
    var method = radioValue('no-pay') || 'cash';
    var shipping = radioValue('no-ship') || 'post';
    var bearer = radioValue('no-bearer') || 'helia';
    var discount = UI.parseInt10($('#no-discount').value) || 0;
    var status = method === 'cash' ? ($('#no-status') || {}).value || 'new' : null;

    if (!neworder.cart.length) { UI.toast('حداقل یک کالا انتخاب کنید', 'warn'); return; }
    if (!customer) { UI.toast('نام مشتری اجباری است', 'warn'); $('#no-customer').focus(); return; }
    if (!UI.isValidPhone(phone)) { UI.toast('شماره تماس معتبر نیست', 'warn'); $('#no-phone').focus(); return; }
    if (!address) { UI.toast('آدرس اجباری است', 'warn'); $('#no-address').focus(); return; }
    if (!UI.isValidPostal(postal)) {
      UI.toast('کد پستی باید دقیقاً ۱۰ رقم باشد', 'warn'); $('#no-postal').focus(); return;
    }

    var mult = null;
    if (method === 'snapp') {
      var raw = UI.parseFloat10($('#no-mult').value);
      if (raw !== null && (raw <= 0 || raw > 10)) { UI.toast('ضریب اسنپ‌پی نامعتبر است', 'warn'); return; }
      mult = raw;
    }

    /* client side pre-check (server recomputes everything anyway) */
    var r = orderCalc();
    if (r && r.error) { UI.toast(r.error, 'warn'); return; }

    var yes = await UI.confirm(
      'سفارش «' + customer + '» به مبلغ ' + UI.money(r.customer_total) + ' ثبت شود؟',
      { title: 'ثبت سفارش', okLabel: 'ثبت نهایی' });
    if (!yes) return;

    var btn = $('#no-save');
    await UI.withBusy(btn, async function () {
      try {
        await DB.createOrder({
          items: neworder.cart.map(function (c) { return { product_id: c.product_id, qty: c.qty }; }),
          customer: customer,
          phone: phone,
          address: address,
          postal_code: UI.normalizePostal(postal),
          shipping_method: shipping,
          method: method,
          discount: discount,
          discount_bearer: bearer,
          snapp_multiplier: mult,
          note: note || null,
          status: status
        });
        UI.toast('سفارش ثبت شد ✓', 'ok');
        resetOrderForm();
        await DB.loadOrders();
        await DB.loadProducts();
        Screens.orders.render();
        if (window.App$ && App$.switchView) App$.switchView('orders');
      } catch (e) { showErr(e); throw e; }
    });
  }

  /* =============================================================== ORDERS */
  var orders = {
    f: { q: '', status: '', pay: '', ship: '', pinned: false },

    render: function () {
      shell('view-orders', 'v1', buildOrders);
      this.refresh();
    },

    refresh: function () {
      var list = $('#ord-list');
      if (!list) return;
      /* never rebuild while the user is typing a tracking code in a card;
         filters/search live outside the list and must keep working */
      if (isFocusedIn(list)) { updateOrdersCount(null); return; }

      var f = orders.f;
      var q = f.q.trim().toLowerCase();
      var qDigits = UI.toEnDigits(q).replace(/\s/g, '');

      var rows = App.orders.filter(function (o) {
        if (f.status && o.status !== f.status) return false;
        if (f.pay && o.method !== f.pay) return false;
        if (f.ship && o.shipping_method !== f.ship) return false;
        if (f.pinned && !o.pinned) return false;
        if (!q) return true;

        var hay = [o.customer, o.phone, o.postal_code, o.tracking, o.note, o.pin_note]
          .concat((o.items || []).map(function (it) { return it.name; }))
          .join(' ').toLowerCase();
        if (hay.indexOf(q) !== -1) return true;
        var digits = UI.toEnDigits(hay).replace(/[\s\-]/g, '');
        return qDigits && digits.indexOf(qDigits) !== -1;
      });

      rows.sort(function (a, b) {
        if (!!a.pinned !== !!b.pinned) return a.pinned ? -1 : 1;
        if (a.pinned && b.pinned) return new Date(b.pinned_at || 0) - new Date(a.pinned_at || 0);
        return new Date(b.created_at) - new Date(a.created_at);
      });

      list.innerHTML = '';
      if (!rows.length) {
        list.appendChild(UI.emptyState('سفارشی پیدا نشد',
          (f.q || f.status || f.pay || f.ship || f.pinned) ? 'فیلترها را پاک کنید' : 'هنوز سفارشی ثبت نشده است'));
      } else {
        rows.forEach(function (o) { list.appendChild(orderCard(o)); });
      }
      updateOrdersCount(rows);
    }
  };

  function buildOrders(h) {
    h.appendChild(el('div', { class: 'view-head' },
      el('h2', { text: 'سفارش‌ها' }),
      el('span', { class: 'spacer' }),
      el('button', {
        class: 'btn small', type: 'button', text: 'خروجی CSV',
        title: 'خروجی اکسل (فارسی)، شامل همه سفارش‌ها',
        onclick: exportCSV
      })
    ));

    var filters = el('div', { class: 'card filters' });
    filters.appendChild(el('div', { class: 'field' },
      el('input', {
        type: 'search', id: 'ord-q', placeholder: 'نام، موبایل، کدپستی، کد رهگیری، محصول…',
        'aria-label': 'جستجو',
        oninput: UI.debounce(function (e) { orders.f.q = e.target.value; orders.refresh(); }, 200)
      })));
    filters.appendChild(el('div', { class: 'field' },
      el('select', {
        id: 'ord-status', 'aria-label': 'وضعیت',
        onchange: function (e) { orders.f.status = e.target.value; orders.refresh(); }
      },
        el('option', { value: '', text: 'همه وضعیت‌ها' }),
        Object.keys(UI.STATUS).map(function (k) { return el('option', { value: k, text: UI.STATUS[k] }); })
      )));
    filters.appendChild(el('div', { class: 'field' },
      el('select', {
        id: 'ord-pay', 'aria-label': 'پرداخت',
        onchange: function (e) { orders.f.pay = e.target.value; orders.refresh(); }
      },
        el('option', { value: '', text: 'همه پرداخت‌ها' }),
        el('option', { value: 'cash', text: 'نقدی / کارت' }),
        el('option', { value: 'snapp', text: 'اسنپ‌پی' })
      )));
    filters.appendChild(el('div', { class: 'field' },
      el('select', {
        id: 'ord-ship', 'aria-label': 'ارسال',
        onchange: function (e) { orders.f.ship = e.target.value; orders.refresh(); }
      },
        el('option', { value: '', text: 'همه روش‌های ارسال' }),
        el('option', { value: 'post', text: 'پست' }),
        el('option', { value: 'courier', text: 'پیک' })
      )));
    filters.appendChild(el('label', { class: 'check' },
      el('input', {
        type: 'checkbox',
        onchange: function (e) { orders.f.pinned = e.target.checked; orders.refresh(); }
      }),
      el('span', { text: 'فقط سنجاق‌شده‌ها' })));
    filters.appendChild(el('div', { class: 'field' },
      el('button', {
        class: 'btn tiny block', type: 'button', text: 'پاک‌کردن فیلترها',
        onclick: function () {
          orders.f = { q: '', status: '', pay: '', ship: '', pinned: false };
          $('#ord-q').value = ''; $('#ord-status').value = ''; $('#ord-pay').value = '';
          $('#ord-ship').value = '';
          var cb = filters.querySelector('input[type=checkbox]'); if (cb) cb.checked = false;
          orders.refresh();
        }
      })));

    h.appendChild(filters);
    h.appendChild(el('p', { class: 'hint', id: 'ord-count' }));
    h.appendChild(el('div', { id: 'ord-list' }));
  }

  function updateOrdersCount(rows) {
    var n = $('#ord-count');
    if (!n) return;
    if (rows === null) return;
    n.textContent = UI.toFaDigits(rows.length) + ' سفارش نمایش داده می‌شود';
  }

  function orderCard(o) {
    var card = el('div', { class: 'card order-card' + (o.pinned ? ' pinned' : ''), dataset: { orderId: o.id } });

    /* header */
    var head = el('div', { class: 'order-head' },
      el('div', { class: 'who' },
        el('div', { class: 'cust', text: o.customer }),
        el('div', { class: 'sub', text: UI.fmtDateTime(o.created_at) + ' · ' + UI.methodLabel(o.method) + ' · ' + UI.shippingLabel(o.shipping_method) })),
      el('div', { class: 'order-actions' },
        UI.statusPill(o.status),
        el('button', {
          class: 'btn tiny pin-btn' + (o.pinned ? ' active' : ''), type: 'button',
          title: o.pinned ? 'برداشتن سنجاق' : 'سنجاق‌زدن برای پیگیری',
          text: (o.pinned ? '📌 سنجاق‌شده' : '📎 سنجاق'),
          onclick: function () { togglePin(o); }
        }))
    );
    if (o.pinned && o.pin_note) {
      head.querySelector('.who').appendChild(el('div', {
        class: 'pill brand', style: 'margin-top:4px', text: '⚠ ' + o.pin_note
      }));
    }
    card.appendChild(head);

    /* items */
    var items = el('div', { class: 'order-items' });
    (o.items || []).forEach(function (it) {
      items.appendChild(el('div', { class: 'oi' },
        el('span', { text: it.name }),
        el('span', { class: 'q', text: UI.toFaDigits(it.qty) + ' × ' + UI.fmtMoney(it.base + it.hp) })));
    });
    card.appendChild(items);

    /* money */
    var money = el('div', { class: 'money-grid' },
      moneyCell('مبلغ مشتری', UI.fmtMoney(o.total), 'hero'),
      moneyCell('به مهدی', UI.fmtMoney(o.owe)),
      moneyCell('سهم هلیا', UI.fmtMoney(o.h_share))
    );
    if (App.isMahdi) {
      var pv = App.privates[o.id];
      money.appendChild(moneyCell('سود مهدی', pv ? UI.fmtMoney(pv.m_profit) : '—'));
    }
    if (o.discount > 0) {
      money.appendChild(moneyCell('تخفیف (' + UI.bearerLabel(o.discount_bearer) + ')', UI.fmtMoney(o.discount), 'warn'));
    }
    if (o.method === 'snapp') {
      money.appendChild(moneyCell('تسویه اسنپ‌پی', UI.fmtMoney(o.payout)));
    }
    if (o.shipping_fee > 0) {
      money.appendChild(moneyCell('هزینه پست', UI.fmtMoney(o.shipping_fee)));
    }
    card.appendChild(money);

    /* tracking */
    var trackInput = el('input', {
      type: 'text', dir: 'ltr', value: o.tracking || '',
      placeholder: o.shipping_method === 'post' ? 'کد رهگیری پستی…' : 'نام پیک / کد رهگیری…',
      'aria-label': 'کد رهگیری'
    });
    var trackSave = el('button', { class: 'btn tiny', type: 'button', text: 'ذخیره کد' });
    trackSave.addEventListener('click', async function () {
      await UI.withBusy(trackSave, async function () {
        try {
          await DB.setTracking(o.id, trackInput.value);
          UI.toast('کد رهگیری ذخیره شد', 'ok', 1500);
          await DB.loadOrders();
          repaintOrders();
        } catch (e) { showErr(e); throw e; }
      });
    });
    card.appendChild(el('div', { class: 'track-row' }, trackInput, trackSave));

    /* status actions */
    var acts = el('div', { class: 'status-actions' });
    UI.nextActions(o).forEach(function (a) {
      acts.appendChild(el('button', {
        class: 'btn small ' + (a.cls || ''), type: 'button', text: a.label,
        onclick: function () { changeStatus(o, a.status); }
      }));
    });
    if (!acts.children.length) {
      acts.appendChild(el('span', { class: 'pill muted', text: 'وضعیت نهایی' }));
    }
    card.appendChild(acts);

    /* footer: postal + phone + note */
    var foot = el('div', { class: 'order-foot' },
      el('span', { text: 'کد پستی: ' }),
      el('b', { dir: 'ltr', style: 'letter-spacing:1px', text: o.postal_code || '—' }),
      el('span', { dir: 'ltr', text: o.phone || '' }),
      o.shipping_method === 'post'
        ? el('span', { class: 'pill muted', text: 'پست' })
        : el('span', { class: 'pill muted', text: 'پیک' })
    );
    card.appendChild(foot);

    if (o.address) {
      card.appendChild(el('p', { class: 'hint', style: 'margin:6px 0 0', text: 'آدرس: ' + o.address }));
    }
    if (o.note) {
      card.appendChild(el('p', { class: 'hint', style: 'margin:2px 0 0', text: 'یادداشت: ' + o.note }));
    }

    /* history */
    if ((o.status_history || []).length) {
      var ol = el('ol', {});
      o.status_history.forEach(function (h) {
        ol.appendChild(el('li', {},
          el('span', { text: UI.statusLabel(h.status) }),
          el('span', { text: '· ' + UI.fmtDateTime(h.at) }),
          h.note ? el('span', { text: '· ' + h.note }) : null));
      });
      card.appendChild(el('details', { class: 'history' },
        el('summary', { text: 'تاریخچه وضعیت‌ها (' + UI.toFaDigits(o.status_history.length) + ')' }),
        ol));
    }

    return card;
  }

  async function togglePin(o) {
    if (o.pinned) {
      try {
        await DB.setPin(o.id, false, null);
        UI.toast('سنجاق برداشته شد', 'ok', 1400);
        await DB.loadOrders();
        repaintOrders();
        if (window.App$ && App$.refresh) App$.refresh(false);
      } catch (e) { showErr(e); }
      return;
    }
    var note = await UI.prompt({
      title: 'سنجاق‌زدن سفارش',
      label: 'دلیل سنجاق (اختیاری) — مثلاً: تحویل داده نشده، مشتری شکایت دارد',
      placeholder: 'دلیل پیگیری…',
      maxlength: 300
    });
    if (note === null) return;
    try {
      await DB.setPin(o.id, true, note);
      UI.toast('سفارش سنجاق شد', 'ok', 1400);
      await DB.loadOrders();
      repaintOrders();
      if (window.App$ && App$.refresh) App$.refresh(false);
    } catch (e) { showErr(e); }
  }

  async function changeStatus(o, target) {
    if (target === 'cancelled') {
      var yes = await UI.confirm(
        'سفارش «' + o.customer + '» لغو شود؟ موجودی کالاها برمی‌گردد و از گزارش‌ها حذف می‌شود.',
        { title: 'لغو سفارش', okLabel: 'لغو سفارش', danger: true });
      if (!yes) return;
      try {
        await DB.cancelOrder(o.id);
        UI.toast('سفارش لغو شد و موجودی برگشت', 'ok');
        await Promise.all([DB.loadOrders(), DB.loadProducts()]);
        repaintOrders();
        if (window.App$ && App$.refresh) App$.refresh(false);
      } catch (e) { showErr(e); }
      return;
    }

    if (target === 'shipped' && o.shipping_method === 'post') {
      var card = document.querySelector('#ord-list .order-card[data-order-id="' + o.id + '"]');
      var trackInput = card ? card.querySelector('.track-row input') : null;
      var val = trackInput ? String(trackInput.value || '').trim() : (o.tracking || '').trim();
      if (!val) {
        UI.toast('برای ارسال پستی، ابتدا کد رهگیری را وارد کنید', 'warn');
        if (trackInput) trackInput.focus();
        return;
      }
      try {
        await DB.setStatus(o.id, target, val, null);
        UI.toast('کد رهگیری ذخیره و سفارش ارسال شد', 'ok');
        await DB.loadOrders();
        repaintOrders();
      } catch (e) { showErr(e); }
      return;
    }

    try {
      await DB.setStatus(o.id, target, null, null);
      UI.toast('وضعیت به «' + UI.statusLabel(target) + '» تغییر کرد', 'ok', 1700);
      await DB.loadOrders();
      repaintOrders();
      if (window.App$ && App$.refresh) App$.refresh(false);
    } catch (e) { showErr(e); }
  }

  function exportCSV() {
    var header = [
      'id', 'created_at (ISO)', 'customer', 'phone', 'postal_code', 'address', 'items',
      'payment', 'shipping', 'shipping_fee', 'snapp_multiplier', 'rounding_step',
      'discount', 'discount_bearer', 'mahdi_discount', 'helia_discount',
      'customer_total', 'owe_to_mahdi', 'helia_share', 'snapp_payout',
      'status', 'tracking', 'pinned', 'pin_note', 'note'
    ];
    if (App.isMahdi) header = header.concat(['cost_total', 'mahdi_profit']);

    var rows = [header];
    App.orders.slice().sort(function (a, b) {
      return new Date(b.created_at) - new Date(a.created_at);
    }).forEach(function (o) {
      var items = (o.items || []).map(function (it) {
        return it.name + ' ×' + it.qty;
      }).join(' | ');
      var r = [
        o.id, o.created_at, o.customer, o.phone, o.postal_code, o.address, items,
        o.method, o.shipping_method, o.shipping_fee, o.snapp_multiplier, o.rounding_step,
        o.discount, o.discount_bearer, o.mahdi_discount, o.helia_discount,
        o.total, o.owe, o.h_share, o.payout,
        UI.statusLabel(o.status), o.tracking, o.pinned ? 'yes' : 'no', o.pin_note, o.note
      ];
      if (App.isMahdi) {
        var pv = App.privates[o.id] || {};
        r.push(pv.cost_total === undefined ? '' : pv.cost_total);
        r.push(pv.m_profit === undefined ? '' : pv.m_profit);
      }
      rows.push(r);
    });
    UI.downloadCSV('delsana-orders-' + UI.toLocalInputDate(new Date()) + '.csv', rows);
    UI.toast('خروجی CSV دانلود شد', 'ok');
  }

  /* ============================================================= ACCOUNTS */
  var accounts = {
    render: function () {
      shell('view-accounts', 'v1', function (h) {
        h.appendChild(el('div', { class: 'view-head' },
          el('h2', { text: 'حساب‌ها' }),
          el('span', { class: 'spacer' }),
          el('button', {
            class: 'btn small', type: 'button', text: 'به‌روزرسانی',
            onclick: function () {
              if (window.App$ && App$.refresh) App$.refresh(true);
            }
          })));
        h.appendChild(el('div', { id: 'acc-body' }));
      });
      this.refresh();
    },

    refresh: function () {
      var body = $('#acc-body');
      if (!body) return;
      if (isFocusedIn(body)) return;
      body.innerHTML = '';

      var live = App.orders.filter(function (o) { return o.status !== 'cancelled'; });

      /* bucket 1: Helia owes Mahdi (paid) */
      var owed = live.filter(function (o) { return o.status === 'paid'; });
      var owedSum = owed.reduce(function (s, o) { return s + Number(o.owe || 0); }, 0);
      body.appendChild(bucketCard({
        title: 'بدهی هلیا به مهدی',
        hint: 'سفارش‌هایی که پول مشتری رسیده ولی هنوز به مهدی منتقل نشده',
        kind: 'owed',
        rows: owed,
        sumLabel: 'جمع بدهی',
        sum: owedSum,
        accent: 'accent',
        bulkLabel: 'ثبت همه به‌عنوان تسویه‌شده',
        bulkTarget: 'settled',
        rowLabel: 'تسویه شد',
        empty: 'بدهی بازی وجود ندارد ✓'
      }));

      /* bucket 2: Snapp Pay pending */
      var snapp = live.filter(function (o) { return o.status === 'awaiting_snapp'; });
      var snappSum = snapp.reduce(function (s, o) { return s + Number(o.payout || 0); }, 0);
      body.appendChild(bucketCard({
        title: 'در انتظار تسویه اسنپ‌پی',
        hint: 'پول این سفارش‌ها هنوز به حساب هلیا نرسیده است',
        kind: 'snapp',
        rows: snapp,
        sumLabel: 'جمع در انتظار',
        sum: snappSum,
        accent: 'warn',
        bulkLabel: 'ثبت همه به‌عنوان دریافت‌شده',
        bulkTarget: 'paid',
        rowLabel: 'پول رسید',
        empty: 'سفارش در انتظار اسنپ‌پی ندارید ✓'
      }));

      /* bucket 3 (Mahdi): ready to ship */
      if (App.isMahdi) {
        var ready = live.filter(function (o) { return o.status === 'settled'; });
        body.appendChild(bucketCard({
          title: 'آماده ارسال',
          hint: 'تسویه شده‌اند و باید از انبار پست/پیک شوند',
          kind: 'ready',
          rows: ready,
          sumLabel: 'جمع مبالغ',
          sum: ready.reduce(function (s, o) { return s + Number(o.total || 0); }, 0),
          accent: 'ok',
          bulkLabel: null,
          bulkTarget: null,
          rowLabel: 'ارسال شد',
          empty: 'سفارشی در انتظار ارسال نیست ✓'
        }));
      }

      if (!body.children.length) {
        body.appendChild(UI.emptyState('چیزی برای نمایش نیست', ''));
      }
    }
  };

  function bucketCard(cfg) {
    var card = el('div', { class: 'card pad-lg' });
    card.appendChild(el('div', { class: 'card-title' },
      el('h3', { text: cfg.title }),
      el('span', { class: 'pill ' + (cfg.accent === 'accent' ? 'brand' : 'muted'),
        text: UI.toFaDigits(cfg.rows.length) + ' سفارش' })));
    card.appendChild(el('p', { class: 'hint', style: 'margin-top:-4px', text: cfg.hint }));

    card.appendChild(el('div', { class: 'stat ' + (cfg.accent || ''), style: 'margin-bottom:10px' },
      el('span', { class: 'label', text: cfg.sumLabel }),
      el('span', { class: 'value', text: UI.fmtMoney(cfg.sum) + ' تومان' })));

    if (!cfg.rows.length) {
      card.appendChild(el('p', { class: 'hint', text: cfg.empty }));
      return card;
    }

    var selectAll = el('input', { type: 'checkbox', checked: true, 'aria-label': 'انتخاب همه' });
    var rowBoxes = [];
    var listWrap = el('div', { style: 'display:flex;flex-direction:column;gap:6px' });

    cfg.rows.forEach(function (o) {
      var box = el('input', { type: 'checkbox', checked: true, 'aria-label': 'انتخاب سفارش ' + o.customer });
      rowBoxes.push(box);
      var row = el('div', { class: 'line-item' },
        box,
        el('div', { class: 'grow' },
          el('div', { class: 'name', text: o.customer }),
          el('div', { class: 'meta', text: UI.fmtDateTime(o.created_at) + ' · ' +
            (cfg.kind === 'snapp' ? UI.money(o.payout) : UI.money(cfg.kind === 'owed' ? o.owe : o.total)) })),
        cfg.rowLabel
          ? el('button', {
              class: 'btn tiny', type: 'button', text: cfg.rowLabel,
              onclick: function () { singleAction(cfg, o); }
            })
          : el('button', {
              class: 'btn tiny', type: 'button', text: 'ارسال',
              onclick: function () { openShip(o); }
            })
      );
      listWrap.appendChild(row);
    });

    selectAll.addEventListener('change', function () {
      rowBoxes.forEach(function (b) { b.checked = selectAll.checked; });
    });

    card.appendChild(listWrap);

    if (cfg.bulkLabel) {
      var bulkBtn = el('button', {
        class: 'btn primary block', type: 'button', style: 'margin-top:12px',
        text: cfg.bulkLabel,
        onclick: async function () {
          var ids = cfg.rows.filter(function (o, i) { return rowBoxes[i].checked; }).map(function (o) { return o.id; });
          if (!ids.length) { UI.toast('حداقل یک سفارش را انتخاب کنید', 'warn'); return; }
          var yes = await UI.confirm(
            UI.toFaDigits(ids.length) + ' سفارش به‌عنوان «' +
            (cfg.bulkTarget === 'settled' ? 'تسویه‌شده' : 'دریافت‌شده') + '» ثبت شود؟',
            { title: cfg.title, okLabel: 'ثبت' });
          if (!yes) return;
          await UI.withBusy(bulkBtn, async function () {
            try {
              var n = await DB.bulkStatus(ids, cfg.bulkTarget);
              UI.toast(UI.toFaDigits(n || 0) + ' سفارش به‌روز شد', 'ok');
              await DB.loadOrders();
              accounts.refresh();
              if (window.App$ && App$.refresh) App$.refresh(false);
            } catch (e) { showErr(e); throw e; }
          });
        }
      });
      card.appendChild(el('label', { class: 'check', style: 'margin-top:10px' },
        selectAll, el('span', { text: 'انتخاب همه' })));
      card.appendChild(bulkBtn);
    }
    return card;
  }

  async function singleAction(cfg, o) {
    try {
      if (cfg.kind === 'ready') {
        await openShip(o);
      } else {
        await DB.setStatus(o.id, cfg.bulkTarget, null, null);
        UI.toast('ثبت شد', 'ok', 1500);
      }
      await DB.loadOrders();
      accounts.refresh();
      if (window.App$ && App$.refresh) App$.refresh(false);
    } catch (e) { showErr(e); }
  }

  async function openShip(o) {
    var tracking = await UI.prompt({
      title: 'ارسال سفارش «' + o.customer + '»',
      label: o.shipping_method === 'post'
        ? 'کد رهگیری پستی (اجباری)'
        : 'نام پیک یا کد رهگیری (اختیاری)',
      placeholder: o.shipping_method === 'post' ? 'مثلاً XX123456789IR' : 'مثلاً آقای رضایی',
      required: o.shipping_method === 'post',
      requiredMessage: 'برای پست، کد رهگیری اجباری است'
    });
    if (tracking === null) return;
    await DB.setStatus(o.id, 'shipped', tracking, null);
    UI.toast('سفارش ارسال شد', 'ok');
    await DB.loadOrders();
    accounts.refresh();
    if (window.App$ && App$.refresh) App$.refresh(false);
  }

  /* ============================================================== REPORTS */
  var reports = {
    range: '7',
    customFrom: null,
    customTo: null,

    render: function () {
      shell('view-reports', 'v1', buildReports);
      this.refresh();
    },

    refresh: function () {
      var body = $('#rep-body');
      if (!body) return;
      UI.qsa('#rep-range .btn').forEach(function (b) {
        b.classList.toggle('active', b.dataset.range === reports.range);
      });
      var customWrap = $('#rep-custom');
      if (customWrap) customWrap.hidden = reports.range !== 'custom';

      var from = null, to = null;
      if (reports.range === 'today') from = UI.startOfDay(new Date());
      else if (reports.range === '7') from = UI.startOfDay(UI.addDays(new Date(), -6));
      else if (reports.range === '30') from = UI.startOfDay(UI.addDays(new Date(), -29));
      else if (reports.range === 'custom') {
        if (reports.customFrom) from = UI.startOfDay(new Date(reports.customFrom + 'T00:00:00'));
        if (reports.customTo) to = UI.startOfDay(UI.addDays(new Date(reports.customTo + 'T00:00:00'), 1));
      }

      var rows = App.orders.filter(function (o) {
        if (o.status === 'cancelled') return false;
        var t = new Date(o.created_at).getTime();
        if (from && t < from.getTime()) return false;
        if (to && t >= to.getTime()) return false;
        return true;
      });

      body.innerHTML = '';
      if (!rows.length) {
        body.appendChild(UI.emptyState('سفارشی در این بازه نیست', 'بازه دیگری را انتخاب کنید'));
        return;
      }

      var total = rows.reduce(function (s, o) { return s + Number(o.total || 0); }, 0);
      var heliaProfit = rows.reduce(function (s, o) { return s + Number(o.h_share || 0); }, 0);
      var mahdiProfit = rows.reduce(function (s, o) {
        var p = App.privates[o.id];
        return s + (p ? Number(p.m_profit || 0) : 0);
      }, 0);
      var dTotal = rows.reduce(function (s, o) { return s + Number(o.discount || 0); }, 0);
      var dMahdi = rows.reduce(function (s, o) { return s + Number(o.mahdi_discount || 0); }, 0);
      var dHelia = rows.reduce(function (s, o) { return s + Number(o.helia_discount || 0); }, 0);

      /* top products by quantity */
      var byProduct = {};
      rows.forEach(function (o) {
        (o.items || []).forEach(function (it) {
          var key = it.product_id || it.name;
          if (!byProduct[key]) byProduct[key] = { name: it.name, qty: 0, sum: 0 };
          byProduct[key].qty += Number(it.qty) || 0;
          byProduct[key].sum += (Number(it.qty) || 0) * (Number(it.base) + Number(it.hp));
        });
      });
      var top = Object.keys(byProduct).map(function (k) { return byProduct[k]; })
        .sort(function (a, b) { return b.qty - a.qty; }).slice(0, 5);
      var maxQty = top.length ? top[0].qty : 1;

      var cashCount = rows.filter(function (o) { return o.method === 'cash'; }).length;
      var snappCount = rows.length - cashCount;
      var cashSum = rows.filter(function (o) { return o.method === 'cash'; })
        .reduce(function (s, o) { return s + Number(o.total || 0); }, 0);
      var snappSum = total - cashSum;
      var postCount = rows.filter(function (o) { return o.shipping_method === 'post'; }).length;
      var courierCount = rows.length - postCount;

      /* KPI cards */
      body.appendChild(el('div', { class: 'grid four', style: 'margin-bottom:12px' },
        statCard('تعداد سفارش', UI.toFaDigits(rows.length), ''),
        statCard('فروش کل', UI.fmtMoney(total) + ' تومان', 'accent'),
        statCard('سود هلیا', UI.fmtMoney(heliaProfit) + ' تومان', 'ok'),
        App.isMahdi ? statCard('سود مهدی', UI.fmtMoney(mahdiProfit) + ' تومان', 'accent') : null
      ));

      /* split: cash vs snapp */
      var splitCard = el('div', { class: 'card' },
        el('div', { class: 'card-title' }, el('h3', { text: 'نقدی در برابر اسنپ‌پی' })),
        el('div', { class: 'split' },
          el('i', { class: 's1', style: 'width:' + (rows.length ? (cashCount / rows.length * 100) : 0) + '%' }),
          el('i', { class: 's2', style: 'width:' + (rows.length ? (snappCount / rows.length * 100) : 0) + '%' })),
        el('div', { class: 'split-legend' },
          el('span', {}, el('i', { style: 'background:var(--brand)' }),
            'نقدی: ' + UI.toFaDigits(cashCount) + ' سفارش · ' + UI.fmtMoney(cashSum)),
          el('span', {}, el('i', { style: 'background:var(--info)' }),
            'اسنپ‌پی: ' + UI.toFaDigits(snappCount) + ' سفارش · ' + UI.fmtMoney(snappSum))),
        el('p', { class: 'hint', style: 'margin-top:8px',
          text: 'ارسال: پست ' + UI.toFaDigits(postCount) + ' · پیک ' + UI.toFaDigits(courierCount) })
      );
      body.appendChild(splitCard);

      /* top products */
      var topCard = el('div', { class: 'card' },
        el('div', { class: 'card-title' }, el('h3', { text: '۵ محصول پرفروش (بر اساس تعداد)' })),
        el('div', { class: 'bar-list' }));
      var barHost = topCard.querySelector('.bar-list');
      if (!top.length) barHost.appendChild(el('p', { class: 'hint', text: 'داده‌ای موجود نیست' }));
      top.forEach(function (t) {
        barHost.appendChild(el('div', { class: 'bar-row' },
          el('div', { class: 'bar-top' },
            el('span', { text: t.name }),
            el('b', { text: UI.toFaDigits(t.qty) + ' عدد · ' + UI.fmtMoney(t.sum) })),
          el('div', { class: 'bar-track' },
            el('div', { class: 'bar-fill', style: 'width:' + (t.qty / maxQty * 100) + '%' }))));
      });
      body.appendChild(topCard);

      /* discounts */
      body.appendChild(el('div', { class: 'card' },
        el('div', { class: 'card-title' }, el('h3', { text: 'تخفیف‌های داده‌شده' })),
        el('table', { class: 'data' },
          el('tbody', {},
            row2('جمع کل تخفیف', UI.fmtMoney(dTotal)),
            row2('بر عهده مهدی', UI.fmtMoney(dMahdi)),
            row2('بر عهده هلیا', UI.fmtMoney(dHelia)),
            row2('بر عهده نصف‌نصف', UI.fmtMoney(dTotal - dMahdi - dHelia))
          ))));

      body.appendChild(el('p', {
        class: 'hint',
        text: 'سفارش‌های لغوشده در این گزارش حساب نمی‌شوند. بازه: ' +
              (reports.range === 'today' ? 'امروز' :
               reports.range === '7' ? '۷ روز اخیر' :
               reports.range === '30' ? '۳۰ روز اخیر' :
               reports.range === 'all' ? 'همه زمان‌ها' : 'بازه دلخواه')
      }));
    }
  };

  function statCard(label, value, cls) {
    return el('div', { class: 'stat ' + (cls || '') },
      el('span', { class: 'label', text: label }),
      el('span', { class: 'value', text: value }));
  }
  function row2(k, v) {
    return el('tr', {}, el('td', { text: k }), el('td', { style: 'text-align:end;font-weight:700', text: v }));
  }

  function buildReports(h) {
    h.appendChild(el('div', { class: 'view-head' }, el('h2', { text: 'گزارش‌ها' })));

    var ranges = [
      { r: 'today', label: 'امروز' },
      { r: '7', label: '۷ روز' },
      { r: '30', label: '۳۰ روز' },
      { r: 'all', label: 'همه' },
      { r: 'custom', label: 'بازه دلخواه' }
    ];
    var bar = el('div', { class: 'range-btns', id: 'rep-range' });
    ranges.forEach(function (x) {
      bar.appendChild(el('button', {
        class: 'btn small', type: 'button', text: x.label, dataset: { range: x.r },
        onclick: function () { reports.range = x.r; reports.refresh(); }
      }));
    });
    h.appendChild(bar);

    h.appendChild(el('div', { class: 'card row wrap', id: 'rep-custom', hidden: true },
      el('div', { class: 'field grow' },
        el('label', { for: 'rep-from', text: 'از تاریخ' }),
        el('input', {
          type: 'date', id: 'rep-from',
          onchange: function (e) { reports.customFrom = e.target.value; reports.refresh(); }
        })),
      el('div', { class: 'field grow' },
        el('label', { for: 'rep-to', text: 'تا تاریخ' }),
        el('input', {
          type: 'date', id: 'rep-to',
          onchange: function (e) { reports.customTo = e.target.value; reports.refresh(); }
        }))));

    h.appendChild(el('div', { id: 'rep-body' }));
  }

  /* ============================================================= SETTINGS */
  var settings = {
    render: function () {
      shell('view-settings', 'v1', buildSettings);
      fillSettings();
      this.refresh();
    },
    refresh: function () { fillSettings(true); }
  };

  function buildSettings(h) {
    h.appendChild(el('div', { class: 'view-head' }, el('h2', { text: 'تنظیمات' })));

    h.appendChild(el('div', { class: 'card pad-lg' },
      el('div', { class: 'alert info', text: 'این مقادیر فقط روی سفارش‌های جدید اعمال می‌شوند؛ سفارش‌های قبلی تغییر نمی‌کنند.' }),
      el('div', { class: 'field' },
        el('label', { for: 'set-post', text: 'هزینه پست پیشتاز (تومان)' }),
        el('input', { type: 'text', id: 'set-post', inputmode: 'numeric', dir: 'ltr' }),
        el('p', { class: 'hint', text: 'پیش‌فرض: ۱۹۰٬۰۰۰ — فقط برای روش ارسال «پست» اضافه می‌شود' })),
      el('div', { class: 'field' },
        el('label', { for: 'set-mult', text: 'ضریب اسنپ‌پی' }),
        el('input', { type: 'text', id: 'set-mult', inputmode: 'decimal', dir: 'ltr' }),
        el('p', { class: 'hint', text: 'پیش‌فرض: ۱٫۱۵ — مبلغ کالاها × این ضیب، سپس گرد می‌شود' })),
      el('div', { class: 'field' },
        el('label', { for: 'set-step', text: 'گرد کردن مبلغ اسنپ‌پی (تومان)' }),
        el('input', { type: 'text', id: 'set-step', inputmode: 'numeric', dir: 'ltr' }),
        el('p', { class: 'hint', text: 'پیش‌فرض: ۵٬۰۰۰ — مبلغ نهایی اسنپ‌پی مضربی از این عدد می‌شود' })),
      el('div', { class: 'row wrap', style: 'margin-top:6px' },
        el('button', {
          class: 'btn primary', id: 'set-save', type: 'button', text: 'ذخیره تنظیمات',
          onclick: saveSettings
        }),
        el('button', {
          class: 'btn', type: 'button', text: 'بازگردانی پیش‌فرض',
          onclick: function () {
            $('#set-post').value = '190000';
            $('#set-mult').value = '1.15';
            $('#set-step').value = '5000';
          }
        }))));

    h.appendChild(el('div', { class: 'card' },
      el('div', { class: 'card-title' }, el('h3', { text: 'در باره اپلیکیشن' })),
      el('p', { class: 'hint', style: 'margin:0',
        text: 'مدیریت دلسانا — نسخه ۱٫۰. همه مبالغ به تومان و بدون اعشار ثبت می‌شوند. ' +
              'داده‌ها به‌صورت زنده بین دو شریک همگام می‌شوند.' })));
  }

  function fillSettings(skipFocused) {
    var p = $('#set-post'), m = $('#set-mult'), s = $('#set-step');
    if (!p) return;
    if (skipFocused) {
      if ([p, m, s].indexOf(document.activeElement) !== -1) return;
    }
    p.value = String(App.settings.post_fee);
    m.value = String(App.settings.snapp_multiplier);
    s.value = String(App.settings.rounding_step);
  }

  async function saveSettings() {
    var post = UI.parseInt10($('#set-post').value);
    var mult = UI.parseFloat10($('#set-mult').value);
    var step = UI.parseInt10($('#set-step').value);
    if (post === null || post < 0) { UI.toast('هزینه پست باید عدد صحیح غیرمنفی باشد', 'warn'); return; }
    if (mult === null || mult <= 0 || mult > 10) { UI.toast('ضریب اسنپ‌پی باید بین ۰ و ۱۰ باشد', 'warn'); return; }
    if (step === null || step <= 0) { UI.toast('گرد کردن باید عدد مثبت باشد', 'warn'); return; }

    await UI.withBusy($('#set-save'), async function () {
      try {
        await DB.saveSettings({ post_fee: post, snapp_multiplier: mult, rounding_step: step });
        UI.toast('تنظیمات ذخیره شد', 'ok');
        fillSettings();
      } catch (e) { showErr(e); throw e; }
    });
  }

  return {
    products: products,
    neworder: neworder,
    orders: orders,
    accounts: accounts,
    reports: reports,
    settings: settings
  };
})();
