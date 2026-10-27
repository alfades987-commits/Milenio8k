const CACHE = 'iptv-v4';
const SHELL = ['./', './index.html', './manifest.json', './icons/icon-192.png', './icons/icon-512.png', './logo.png'];
const HLS = 'https://cdnjs.cloudflare.com/ajax/libs/hls.js/1.5.8/hls.min.js';

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => {
    c.add(new Request(HLS, {mode: 'no-cors'})).catch(() => {});
    return c.addAll(SHELL);
  }).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(caches.keys()
    .then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  const isShell = url.origin === location.origin || req.url === HLS;
  if (!isShell) return; // los streams de video nunca se cachean
  e.respondWith(
    fetch(req).then(res => {
      const copy = res.clone();
      caches.open(CACHE).then(c => c.put(req, copy));
      return res;
    }).catch(() => caches.match(req).then(r => r || caches.match('./index.html')))
  );
});
