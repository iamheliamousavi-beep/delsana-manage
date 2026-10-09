/* sw.js — Delsana PWA service worker.
   Static shell: cache-first (revalidated in background).
   Supabase/API calls: never cached (always network, never POST).
   Version the CACHE name on every deploy that changes static files. */
'use strict';

var CACHE = 'delsana-v5';
var SHELL = [
  './index.html',
  './style.css',
  './calc.js',
  './ui.js',
  './db.js',
  './screens.js',
  './app.js',
  './manifest.json',
  './icon.svg',
  './icon-192.png',
  './icon-512.png'
];

self.addEventListener('install', function (event) {
  event.waitUntil(
    caches.open(CACHE).then(function (cache) {
      /* addAll fails as a whole if one entry 404s, so add one by one */
      return Promise.all(SHELL.map(function (url) {
        return cache.add(new Request(url, { cache: 'reload' })).catch(function () { /* optional */ });
      }));
    }).then(function () { return self.skipWaiting(); })
  );
});

self.addEventListener('activate', function (event) {
  event.waitUntil(
    caches.keys().then(function (keys) {
      return Promise.all(keys.map(function (k) {
        return k === CACHE ? null : caches.delete(k);
      }));
    }).then(function () { return self.clients.claim(); })
  );
});

self.addEventListener('fetch', function (event) {
  var req = event.request;
  if (req.method !== 'GET') return;                      /* POST/PUT/DELETE → network only */

  var url = new URL(req.url);
  if (url.origin !== self.location.origin) return;        /* CDN/fonts → browser default */

  /* navigations: network first so a new deploy is picked up immediately */
  if (req.mode === 'navigate') {
    event.respondWith(
      fetch(req).then(function (res) {
        if (res && res.ok) {
          var copy = res.clone();
          caches.open(CACHE).then(function (c) { c.put('./index.html', copy); });
        }
        return res;
      }).catch(function () {
        return caches.match('./index.html');
      })
    );
    return;
  }

  /* static assets: cache first, refresh in background */
  event.respondWith(
    caches.match(req).then(function (hit) {
      var net = fetch(req).then(function (res) {
        if (res && res.ok) {
          var copy = res.clone();
          caches.open(CACHE).then(function (c) { c.put(req, copy); });
        }
        return res;
      }).catch(function () { return hit; });
      return hit || net;
    })
  );
});

/* --------------------------------------------------------------- web push */
/* section 9.5: every push MUST show a visible notification */

self.addEventListener('push', function (event) {
  var data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch (e) {
    data = { body: event.data ? event.data.text() : '' };
  }
  var title = data.title || 'دلسانا';
  var options = {
    body: data.body || '',
    tag: data.tag || undefined,
    lang: 'fa',
    dir: 'rtl',
    icon: 'icon-192.png',
    badge: 'icon-192.png',
    data: { url: data.url || './' }
  };
  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', function (event) {
  event.notification.close();
  var url = (event.notification.data && event.notification.data.url) || './';
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function (list) {
      for (var i = 0; i < list.length; i++) {
        var c = list[i];
        if (c.url && 'focus' in c) {
          c.focus();
          if ('navigate' in c) c.navigate(url);   /* reuse the open app tab */
          return undefined;
        }
      }
      if (self.clients.openWindow) return self.clients.openWindow(url);
      return undefined;
    })
  );
});

/* best effort: the app re-saves the new subscription on its next start */
self.addEventListener('pushsubscriptionchange', function (event) {
  event.waitUntil(resubscribe());
});

function vapidKey() {
  return caches.match('./vapid.key').then(function (res) {
    return res ? res.text() : null;
  });
}

function resubscribe() {
  return vapidKey().then(function (key) {
    if (!key || key.indexOf('YOUR_') === 0) return null;
    return self.registration.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: urlBase64ToUint8Array(key)
    });
  }).catch(function () { return null; });
}

function urlBase64ToUint8Array(base64String) {
  var padding = '='.repeat((4 - (base64String.length % 4)) % 4);
  var base64 = (base64String + padding).replace(/-/g, '+').replace(/_/g, '/');
  var raw = atob(base64);
  var out = new Uint8Array(raw.length);
  for (var i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out;
}
