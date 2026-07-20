/* officecamp スマホ版 Service Worker
 * 方針: 「アプリシェルのみキャッシュ」。
 * Supabase のライブデータ（および CDN の supabase-js）はキャッシュしない＝
 * データの陳腐化・不整合を避けるため、同一オリジンの静的シェルだけを扱う。
 * 更新手順: シェル（app.html 等）を変えたら VERSION を上げる → 旧キャッシュは activate で破棄。
 */
const VERSION = 'v9';
const CACHE_NAME = 'officecamp-shell-' + VERSION;

// プレキャッシュするアプリシェル（すべて同一オリジン・相対パス）
const SHELL_ASSETS = [
  './app.html',
  './config.js',
  './manifest.json',
  './icons/icon-192.png',
  './icons/icon-512.png',
  './icons/icon-maskable-192.png',
  './icons/icon-maskable-512.png',
  './icons/apple-touch-icon.png',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) => cache.addAll(SHELL_ASSETS))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(
        keys.filter((k) => k.startsWith('officecamp-shell-') && k !== CACHE_NAME)
            .map((k) => caches.delete(k))
      ))
      .then(() => self.clients.claim())
  );
});

// オフライン時の最終フォールバック（app.html すらキャッシュに無い場合のみ）
const OFFLINE_HTML = `<!DOCTYPE html><html lang="ja"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>オフライン - officecamp</title>
<style>body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
background:#F4F4F5;color:#1A1A1A;font-family:-apple-system,BlinkMacSystemFont,"Hiragino Sans","Noto Sans JP",sans-serif}
.box{text-align:center;padding:24px}.box h1{font-size:20px;margin:0 0 8px}.box p{color:#6B6B6B;font-size:14px;margin:0 0 16px}
.box button{padding:10px 24px;border:none;border-radius:12px;background:#1A1A1A;color:#fff;font-size:14px;font-weight:700}</style>
</head><body><div class="box"><h1>オフラインです</h1><p>ネットワークに接続してから再読み込みしてください。</p>
<button onclick="location.reload()">再読み込み</button></div></body></html>`;

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;               // 書き込み系はすべて素通し
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return; // Supabase / CDN 等クロスオリジンは一切触らない（network-only）

  // 画面遷移（app.html 本体）: network-first。オフライン時のみキャッシュ → 最終フォールバック
  if (req.mode === 'navigate') {
    event.respondWith(
      fetch(req)
        .then((res) => {
          // './app.html' キーに保存するのは app.html 本体の応答のみ。
          // pc.html や index.html の応答を混ぜると、オフライン時のフォールバックが別画面になる。
          if (res && res.ok && url.pathname.endsWith('/app.html')) {
            const copy = res.clone();
            caches.open(CACHE_NAME).then((c) => c.put('./app.html', copy));
          }
          return res;
        })
        .catch(() =>
          caches.match('./app.html').then((cached) =>
            cached || new Response(OFFLINE_HTML, { headers: { 'Content-Type': 'text/html; charset=utf-8' } })
          )
        )
    );
    return;
  }

  // 同一オリジンの静的アセット: network-first（鮮度優先）、失敗時のみキャッシュ
  event.respondWith(
    fetch(req)
      .then((res) => {
        if (res && res.ok) {
          const copy = res.clone();
          caches.open(CACHE_NAME).then((c) => c.put(req, copy));
        }
        return res;
      })
      .catch(() => caches.match(req).then((cached) => cached || Response.error()))
  );
});
