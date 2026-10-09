/* db.js — Supabase data layer. Everything the UI needs to talk to the
   backend lives here. Only the anon key is ever used (see app.js config). */
(function (root) {
  'use strict';

  /* Shared application state (read by screens.js / app.js). */
  var App = root.App = {
    supabase: null,
    user: null,
    profile: null,
    role: null,
    isMahdi: false,
    settings: { post_fee: 190000, snapp_multiplier: 1.15, rounding_step: 5000 },
    products: [],
    orders: [],
    view: 'products',
    online: true,
    channel: null,
    syncedAt: null
  };

  var DEFAULTS = { post_fee: 190000, snapp_multiplier: 1.15, rounding_step: 5000 };

  function fail(error) {
    /* PostgrestError / AuthError / fetch errors all end up here */
    var e = error instanceof Error ? error : new Error((error && error.message) || String(error));
    if (error && error.code) e.code = error.code;
    e.raw = (error && error.message) || String(error);
    throw e;
  }

  async function unwrap(promise) {
    var res = await promise;
    if (res && res.error) fail(res.error);
    return res ? res.data : res;
  }

  /* Page through a table (Supabase caps each request at 1000 rows). */
  async function fetchAll(table, select, orderCol, ascending) {
    var out = [];
    var from = 0;
    var pageSize = 1000;
    for (;;) {
      var query = App.supabase.from(table).select(select).range(from, from + pageSize - 1);
      if (orderCol) query = query.order(orderCol, { ascending: ascending === true });
      var res = await query;
      if (res.error) fail(res.error);
      var rows = res.data || [];
      out = out.concat(rows);
      if (rows.length < pageSize) break;
      from += pageSize;
      if (from > 50000) break;
    }
    return out;
  }

  var DB = {};

  /* ------------------------------------------------------------ lifecycle */
  DB.init = function (config) {
    if (!root.supabase) throw new Error('کتابخانه Supabase بارگذاری نشد');
    if (!config || !config.url || !config.anonKey ||
        config.url.indexOf('YOUR_') !== -1 || config.anonKey.indexOf('YOUR_') !== -1) {
      throw new Error('config in app.js is not filled in yet');
    }
    App.supabase = root.supabase.createClient(config.url, config.anonKey, {
      auth: {
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: false,
        storageKey: 'delsana-auth'
      }
    });
    return App.supabase;
  };

  DB.getSession = async function () {
    var data = await unwrap(App.supabase.auth.getSession());
    return data ? data.session : null;
  };

  DB.onAuth = function (cb) {
    return App.supabase.auth.onAuthStateChange(function (event, session) {
      cb(event, session);
    });
  };

  DB.signIn = async function (email, password) {
    var data = await unwrap(App.supabase.auth.signInWithPassword({ email: email, password: password }));
    return data ? data.session : null;
  };

  DB.signOut = async function () {
    try { await App.supabase.auth.signOut(); } catch (e) { /* already signed out */ }
    App.user = null; App.profile = null; App.role = null; App.isMahdi = false;
    App.products = []; App.orders = [];
  };

  /* Load the signed-in user's profile row (role). */
  DB.loadProfile = async function () {
    if (!App.user) return null;
    var rows = await unwrap(
      App.supabase.from('profiles').select('user_id, role').eq('user_id', App.user.id).limit(1)
    );
    App.profile = rows && rows[0] ? rows[0] : null;
    App.role = App.profile ? App.profile.role : null;
    App.isMahdi = App.role === 'mahdi';
    return App.profile;
  };

  /* ------------------------------------------------------------------ rpc */
  DB.rpc = async function (name, args) {
    return unwrap(App.supabase.rpc(name, args || {}));
  };

  /* -------------------------------------------------------------- settings */
  /* Read one numeric setting. `null`/empty/non-finite means "keep the
     default"; 0 is a perfectly valid post_fee, so never use `x || default`.
     snapp_multiplier and rounding_step additionally have to be > 0. */
  function readSetting(raw, def, allowZero) {
    if (raw === null || raw === undefined || raw === '') return def;
    var v = Number(raw);
    if (!isFinite(v)) return def;
    if (allowZero ? v < 0 : v <= 0) return def;
    return v;
  }

  DB.loadSettings = async function () {
    var rows = await unwrap(App.supabase.from('settings').select('key, value'));
    var s = { post_fee: DEFAULTS.post_fee, snapp_multiplier: DEFAULTS.snapp_multiplier, rounding_step: DEFAULTS.rounding_step };
    (rows || []).forEach(function (r) {
      if (r.key === 'post_fee') s.post_fee = Math.trunc(readSetting(r.value, DEFAULTS.post_fee, true));
      else if (r.key === 'snapp_multiplier') s.snapp_multiplier = readSetting(r.value, DEFAULTS.snapp_multiplier, false);
      else if (r.key === 'rounding_step') s.rounding_step = Math.trunc(readSetting(r.value, DEFAULTS.rounding_step, false));
    });
    App.settings = s;
    return s;
  };

  DB.saveSettings = async function (s) {
    /* `settings` has no INSERT policy (section 5.2), so upsert always fails.
       The three rows are created by setup.sql; only UPDATE is ever needed. */
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

  /* -------------------------------------------------------------- products */
  DB.loadProducts = async function () {
    App.products = await fetchAll(
      'products', 'id, name, base_price, hp, available, archived, created_at', 'name', true
    );
    return App.products;
  };

  DB.addProduct = async function (p) {
    await DB.rpc('add_product', {
      p_name: p.name, p_base_price: p.base_price, p_hp: p.hp,
      p_available: p.available === undefined ? true : !!p.available
    });
    await DB.loadProducts();
  };

  DB.updateProduct = async function (p) {
    await DB.rpc('update_product', { p_id: p.id, p_name: p.name, p_archived: !!p.archived });
    await DB.loadProducts();
  };

  DB.setHp = async function (id, hp) {
    await DB.rpc('set_hp', { p_id: id, p_hp: hp });
    await DB.loadProducts();
  };

  DB.setBasePrice = async function (id, price) {
    await DB.rpc('set_base_price', { p_id: id, p_price: price });
    await DB.loadProducts();
  };

  DB.setAvailability = async function (id, available) {
    await DB.rpc('set_availability', { p_id: id, p_available: !!available });
    await DB.loadProducts();
  };

  DB.bulkPriceUpdate = async function (ids, mode, value) {
    var n = await DB.rpc('bulk_price_update', { p_ids: ids, p_mode: mode, p_value: value });
    await DB.loadProducts();
    return n;
  };

  /* ---------------------------------------------------------------- orders */
  DB.loadOrders = async function () {
    var orders = await fetchAll(
      'orders',
      'id, created_at, customer, phone, address, postal_code, items, method, shipping_method, ' +
      'shipping_fee, snapp_multiplier, rounding_step, discount, discount_bearer, mahdi_discount, ' +
      'helia_discount, total, owe, h_share, payout, status, status_history, tracking, note, ' +
      'pinned, pin_note, pinned_at',
      'created_at', false
    );
    App.orders = orders;
    return App.orders;
  };

  DB.createOrder = async function (payload) {
    var id = await DB.rpc('create_order', {
      p_items: payload.items,
      p_customer: payload.customer,
      p_phone: payload.phone,
      p_address: payload.address,
      p_postal_code: payload.postal_code,
      p_shipping_method: payload.shipping_method,
      p_method: payload.method,
      p_discount: payload.discount || 0,
      p_discount_bearer: payload.discount_bearer || 'helia',
      p_snapp_multiplier: payload.snapp_multiplier,
      p_note: payload.note || null,
      p_status: payload.status || null
    });
    return id;
  };

  DB.setStatus = async function (id, status, tracking, note) {
    await DB.rpc('set_order_status', {
      p_order_id: id, p_status: status,
      p_tracking: tracking === undefined ? null : tracking,
      p_note: note || null
    });
  };

  DB.cancelOrder = async function (id) {
    await DB.rpc('cancel_order', { p_order_id: id });
  };

  DB.setTracking = async function (id, tracking) {
    await DB.rpc('set_tracking', { p_order_id: id, p_tracking: tracking });
  };

  /* section 7.1 — customer data only, money is never editable */
  DB.updateOrderInfo = async function (id, data) {
    await DB.rpc('update_order_info', {
      p_order_id: id,
      p_customer: data.customer,
      p_phone: data.phone,
      p_address: data.address || null,
      p_postal_code: data.postal_code,
      p_note: data.note || null
    });
  };

  DB.setPin = async function (id, pinned, note) {
    await DB.rpc('set_pin', { p_order_id: id, p_pinned: pinned, p_pin_note: note || null });
  };

  DB.bulkStatus = async function (ids, target) {
    var n = await DB.rpc('bulk_set_status', { p_order_ids: ids, p_target: target });
    return n || 0;
  };

  /* --------------------------------------------------- notifications (9.5) */
  /* JWT-protected Edge Functions, called with the signed-in user's token */
  DB.fn = async function (name, body) {
    var res = await App.supabase.functions.invoke(name, { body: body || {} });
    if (res && res.error) fail(res.error);
    return res ? res.data : res;
  };

  DB.createTelegramLink = function () {
    return DB.rpc('create_telegram_link');
  };

  DB.notificationStatus = function () {
    return DB.rpc('my_notification_status');
  };

  DB.disconnectTelegram = function () {
    return DB.rpc('disconnect_telegram');
  };

  DB.sendInvoice = function (orderId) {
    return DB.fn('send-invoice', { order_id: orderId });
  };

  /* -------------------------------------------------------------- realtime */
  DB.subscribe = function (onChange) {
    if (App.channel) return App.channel;
    var ch = App.supabase.channel('delsana-realtime');
    ['orders', 'products', 'settings'].forEach(function (table) {
      ch = ch.on('postgres_changes', { event: '*', schema: 'public', table: table },
        function (payload) { onChange(table, payload); });
    });
    ch.subscribe(function (status) {
      if (status === 'SUBSCRIBED') App.syncedAt = new Date().toISOString();
    });
    App.channel = ch;
    return ch;
  };

  DB.unsubscribe = function () {
    if (App.channel) {
      try { App.supabase.removeChannel(App.channel); } catch (e) { /* ignore */ }
      App.channel = null;
    }
  };

  /* --------------------------------------------------------------- online */
  DB.watchNetwork = function () {
    var update = function (online) {
      App.online = online;
      if (!online) UI.toast('آفلاین هستید؛ آخرین اطلاعات نمایش داده می‌شود', 'warn');
      else UI.toast('اتصال برقرار شد', 'ok');
    };
    window.addEventListener('online', function () { update(true); });
    window.addEventListener('offline', function () { update(false); });
    App.online = navigator.onLine !== false;
  };

  root.DB = DB;
})(window);
