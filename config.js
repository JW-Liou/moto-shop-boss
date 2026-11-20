const SUPABASE_URL = "https://uqcjyralyukkdawzgbrc.supabase.co";
const SUPABASE_KEY = "sb_publishable_AbtXZ2lhjEqe-32_MKUhvg_Woyf3v1h";
const db = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);


// 啟動 Service Worker，讓系統可以安裝成 App（PWA）
if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("sw.js");
}