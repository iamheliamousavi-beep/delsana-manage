/* sw.js — Delsana PWA service worker.
   Static shell: cache-first (revalidated in background).
   Supabase/API calls: never cached (always network, never POST).
   Version the CACHE name on every deploy that changes static files. */
'use strict';

var CACHE = 'delsana-v4';
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
