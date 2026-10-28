/* Service worker: l'app si apre anche senza rete.
   Cambia VERSION quando pubblichi una nuova versione (e APP_V in app.html). */
const VERSION = 'pl-v1';
const SHELL = ['./', 'index.html', 'app.html', 'config.js', 'manifest.webmanifest', 'icon-192.png'];

self.addEventListener('install', e => {
  self.skipWaiting();
  e.waitUntil(caches.open(VERSION).then(c => c.addAll(SHELL)).catch(() => {}));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== VERSION).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const r = e.request;
  if (r.method !== 'GET') return;
  const u = new URL(r.url);
  if (u.hostname.endsWith('.supabase.co')) return;           // i dati passano sempre dalla rete
  if (r.mode === 'navigate' || u.pathname.endsWith('config.js')) {   // pagine: prima la rete, poi la copia salvata
    e.respondWith(fetch(r).then(res => { const cp = res.clone(); caches.open(VERSION).then(c => c.put(r, cp)); return res; })
      .catch(() => caches.match(r).then(h => h || caches.match(r, {ignoreSearch: true})).then(h => h || caches.match('index.html'))));
    return;
  }
  e.respondWith(caches.open(VERSION).then(async c => {        // font e librerie: copia salvata + aggiornamento in background
    const hit = await c.match(r);
    const net = fetch(r).then(res => { if (res && (res.ok || res.type === 'opaque')) c.put(r, res.clone()); return res; }).catch(() => hit);
    return hit || net;
  }));
});
