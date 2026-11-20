// Service Worker：讓系統可以「安裝」成 App
// 這裡刻意「不做離線快取」，每次都從網路拿最新版，
// 這樣你 Push 新版之後，大家打開就是新的，不會卡在舊畫面。

self.addEventListener("install", () => self.skipWaiting());

self.addEventListener("activate", event => {
  event.waitUntil(self.clients.claim());
});

// 什麼都不攔截，讓瀏覽器照平常的方式去網路抓資料
self.addEventListener("fetch", () => {});