/* ==========================================================================
   Delsana Management — app.js
   1) CONFIG (fill these two values before deploying)
   2) authentication, navigation, realtime sync, service worker
   ========================================================================== */

/* -------------------------------------------------------------- CONFIG --- */
const CONFIG = {
  /* Supabase Dashboard -> Project Settings -> API */
  supabaseUrl: 'https://jmeloxuzdhabbszkthgt.supabase.co',        /* e.g. https://abcdefgh.supabase.co */
  supabaseAnonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImptZWxveHV6ZGhhYmJzemt0aGd0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTEyOTIwNDYsImV4cCI6MjEwNjg2ODA0Nn0.0y6-W_ACDcGw4DHwtle7u6oO4zDnw5hRpZODvo4xkO0', /* the "anon public" key only        */
  /* Telegram bot of the app (no @), Dashboard -> Edge Functions -> Secrets */
  telegramBotUsername: 'YOUR_BOT_USERNAME'                        /* e.g. DelsanaBot                   */
};
/* ------------------------------------------------------------------------ */

(function () {
  'use strict';

  var $ = UI.qs;
  var VIEWS = ['products', 'neworder', 'orders', 'accounts', 'reports', 'settings'];
  var TITLES = {
    products: 'محصولات',
    neworder: 'سفارش جدید',
    orders: 'سفارش‌ها',
    accounts: 'حساب‌ها',
    reports: 'گزارش‌ها',
    settings: 'تنظیمات'
  };
  /* display names only (section 4); the roles stay `mahdi` / `helia` */
  var ROLE_LABEL = UI.PARTY_LABEL;

  var state = {
    ready: false,
    entering: false,
    userId: null,
    view: 'products',
    refreshTimer: null
  };

  /* ---------------------------------------------------------------- boot */
  function showBoot() {
    var b = $('#boot');
    if (b) { b.hidden = false; b.classList.remove('done'); }
  }
  function hideBoot() {
    var b = $('#boot');
    if (!b) return;
    b.classList.add('done');
    setTimeout(function () { b.hidden = true; }, 320);
  }

  function showLogin(message) {
    $('#main').hidden = true;
    $('#screen-login').hidden = false;
    var err = $('#login-error');
    if (message) { err.textContent = message; err.hidden = false; }
    else { err.hidden = true; err.textContent = ''; }
  }

  function showMain() {
    $('#screen-login').hidden = true;
    $('#main').hidden = false;
  }

  function updateUserChip() {
    var chip = $('#user-chip');
    if (!App.role) { chip.hidden = true; return; }
    chip.hidden = false;
    chip.textContent = ROLE_LABEL[App.role] || App.role;
  }

  function configError() {
    return CONFIG.supabaseUrl.indexOf('YOUR_') === 0 || CONFIG.supabaseAnonKey.indexOf('YOUR_') === 0 ||
           !CONFIG.supabaseUrl || !CONFIG.supabaseAnonKey;
  }

  /* -------------------------------------------------------------- session */
  async function enterApp(session) {
    if (state.entering) return;
    if (session && state.userId === session.user.id && App.profile) return;
    state.entering = true;
    try {
      App.user = session.user;
      state.userId = session.user.id;
      await DB.loadProfile();

      if (!App.profile) {
        await DB.signOut();
        state.userId = null;
        App.user = null;
        showLogin('پروفایل شما در سیستم ثبت نشده است. از مدیر بخواهید نقش شما را تعریف کند.');
        return;
      }

      updateUserChip();
      await DB.loadSettings();
      showMain();
      /* loading state: skeleton rows until the first data round-trip ends */
      var firstView = localStorage.getItem('delsana-view') || 'products';
      var host = document.getElementById('view-' + firstView);
      if (host) { host.dataset.shell = ''; UI.skeletons(host, 4); }
      await refreshData(true);
      switchView(localStorage.getItem('delsana-view') || 'products', true);
      startRealtime();
      startPolling();
      state.ready = true;
    } catch (e) {
      UI.toast(UI.errMessage(e), 'err');
      showLogin(UI.errMessage(e));
    } finally {
      state.entering = false;
    }
  }

  async function leaveApp() {
    state.ready = false;
    state.userId = null;
    stopRealtime();
    stopPolling();
    await DB.signOut();
    showLogin();
  }

  /* ----------------------------------------------------------- navigation */
  function switchView(name, force) {
    if (VIEWS.indexOf(name) === -1) name = 'products';
    if (!force && state.view === name && !$('#view-' + name).hidden) return;
    state.view = name;
    App.view = name;
    try { localStorage.setItem('delsana-view', name); } catch (e) { /* private mode */ }

    VIEWS.forEach(function (v) {
      var sec = $('#view-' + v);
      if (sec) sec.hidden = v !== name;
    });
    UI.qsa('#tabbar .tab').forEach(function (t) {
      var active = t.dataset.view === name;
      t.classList.toggle('active', active);
      t.setAttribute('aria-current', active ? 'page' : 'false');
    });
    $('#view-title').textContent = TITLES[name] || '';

    var screen = Screens[name];
    if (screen && screen.render) {
      Promise.resolve()
        .then(function () { return screen.render(); })
        .catch(function (e) { UI.toast(UI.errMessage(e), 'err'); });
    }
    window.scrollTo({ top: 0, behavior: 'instant' in window ? 'instant' : 'auto' });
  }

  /* --------------------------------------------------------------- data */
  async function refreshData(showSpinner) {
    var btn = $('#btn-refresh');
    if (showSpinner && btn) btn.classList.add('busy');
    try {
      await Promise.all([DB.loadProducts(), DB.loadOrders(), DB.loadSettings()]);
      updatePinnedBadge();
      var screen = Screens[state.view];
      if (screen && screen.refresh) await screen.refresh();
    } finally {
      if (showSpinner && btn) btn.classList.remove('busy');
    }
  }

  function updatePinnedBadge() {
    var n = App.orders.filter(function (o) { return o.pinned && o.status !== 'cancelled'; }).length;
    var badge = $('#badge-pinned');
    if (!badge) return;
    badge.hidden = n === 0;
    badge.textContent = UI.toFaDigits(String(n));
    badge.setAttribute('aria-label', UI.toFaDigits(String(n)) + ' سفارش سنجاق‌شده');
  }

  /* ------------------------------------------------------------ realtime */
  function startRealtime() {
    stopRealtime();
    if (!App.supabase) return;
    var handler = UI.debounce(function () {
      if (!state.ready) return;
      refreshData(false).catch(function () { /* handled by toast */ });
    }, 600);
    DB.subscribe(function () { handler(); });
  }
  function stopRealtime() { DB.unsubscribe(); }

  function startPolling() {
    stopPolling();
    state.refreshTimer = setInterval(function () {
      if (!state.ready) return;
      if (document.visibilityState !== 'visible') return;
      if (!App.online) return;
      refreshData(false).catch(function () { /* ignore */ });
    }, 45000);
  }
  function stopPolling() {
    if (state.refreshTimer) clearInterval(state.refreshTimer);
    state.refreshTimer = null;
  }

  /* --------------------------------------------------------------- login */
  function bindLogin() {
    $('#login-form').addEventListener('submit', function (e) {
      e.preventDefault();
      var email = $('#login-email').value.trim();
      var pass = $('#login-password').value;
      var errBox = $('#login-error');

      if (!email || !pass) {
        errBox.textContent = 'ایمیل و رمز عبور را وارد کنید';
        errBox.hidden = false;
        return;
      }
      if (configError()) {
        errBox.textContent = 'مقادیر Supabase در ابتدای فایل app.js هنوز تنظیم نشده‌اند.';
        errBox.hidden = false;
        return;
      }

      errBox.hidden = true;
      UI.withBusy($('#login-btn'), async function () {
        try {
          var session = await DB.signIn(email, pass);
          if (session) await enterApp(session);
        } catch (e) {
          errBox.textContent = UI.errMessage(e);
          errBox.hidden = false;
          throw e;
        }
      }).catch(function () { /* message already shown */ });
    });
  }

  /* ------------------------------------------------------------ bindings */
  function bindShell() {
    UI.qsa('#tabbar .tab').forEach(function (tab) {
      tab.addEventListener('click', function () { switchView(tab.dataset.view); });
    });

    $('#btn-refresh').addEventListener('click', function () {
      var btn = this;
      if (!state.ready) return;
      btn.classList.add('busy');
      refreshData(true)
        .then(function () { UI.toast('به‌روزرسانی شد', 'ok', 1500); })
        .catch(function (e) { UI.toast(UI.errMessage(e), 'err'); })
        .finally(function () { btn.classList.remove('busy'); });
    });

    $('#btn-logout').addEventListener('click', function () {
      UI.confirm('از حساب خارج می‌شوید؟', { okLabel: 'خروج', danger: true, title: 'خروج از حساب' })
        .then(function (yes) { if (yes) leaveApp(); });
    });
  }

  /* ------------------------------------------------------------------ sw */
  function registerSW() {
    if (!('serviceWorker' in navigator)) return;
    if (location.protocol !== 'https:' && location.hostname !== 'localhost' &&
        location.hostname !== '127.0.0.1') return;
    navigator.serviceWorker.register('sw.js').catch(function () { /* not fatal */ });
  }

  /* ------------------------------------------------------------ errors */
  function bindErrors() {
    window.addEventListener('unhandledrejection', function (e) {
      if (!e.reason) return;
      e.preventDefault();
      UI.toast(UI.errMessage(e.reason), 'err');
    });
    window.addEventListener('error', function () { /* keep the app alive */ });
  }

  /* ---------------------------------------------------------------- main */
  async function boot() {
    showBoot();
    bindLogin();
    bindShell();
    bindErrors();
    DB.watchNetwork();
    registerSW();

    try {
      DB.init({ url: CONFIG.supabaseUrl, anonKey: CONFIG.supabaseAnonKey });
    } catch (e) {
      hideBoot();
      showLogin(configError()
        ? 'ابتدا مقادیر Supabase را در ابتدای فایل app.js تنظیم کنید.'
        : UI.errMessage(e));
      return;
    }

    DB.onAuth(function (event, session) {
      if (event === 'SIGNED_OUT' || !session) {
        if (state.userId) leaveApp();
        return;
      }
      enterApp(session);
    });

    try {
      var session = await DB.getSession();
      if (session) await enterApp(session);
      else showLogin();
    } catch (e) {
      showLogin(UI.errMessage(e));
    } finally {
      hideBoot();
    }

    window.App$ = { switchView: switchView, refresh: refreshData, boot: boot };
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
