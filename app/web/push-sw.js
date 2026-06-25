// Dedicated Web Push service worker for ONROL Learn.
//
// This is intentionally separate from Flutter's PWA worker (which we keep
// disabled via --pwa-strategy=none). It does NOT intercept fetches or cache any
// app assets, so it can never serve a stale build — it only shows notifications
// pushed from the server and focuses the app when one is tapped.

self.addEventListener('install', function () {
  // Activate immediately so a freshly-registered worker can receive pushes.
  self.skipWaiting();
});

self.addEventListener('activate', function (event) {
  event.waitUntil(self.clients.claim());
});

self.addEventListener('push', function (event) {
  var data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch (e) {
    data = { title: 'ONROL Learn', body: event.data ? event.data.text() : '' };
  }
  var title = data.title || 'ONROL Learn';
  var options = {
    body: data.body || '',
    icon: 'icons/Icon-192.png',
    badge: 'icons/Icon-192.png',
    tag: data.tag || undefined,
    renotify: !!data.tag,
    data: { url: data.url || '/' }
  };
  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', function (event) {
  event.notification.close();
  var url = (event.notification.data && event.notification.data.url) || '/';
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function (list) {
      for (var i = 0; i < list.length; i++) {
        var client = list[i];
        if ('focus' in client) {
          if ('navigate' in client) { try { client.navigate(url); } catch (e) {} }
          return client.focus();
        }
      }
      if (self.clients.openWindow) return self.clients.openWindow(url);
    })
  );
});
