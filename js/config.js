const SUPABASE_URL = "https://kqkezlofptqgybevuehf.supabase.co";   // 老闆版專用的資料庫
const SUPABASE_KEY = "sb_publishable_t5CB75GK5SDeZq4Jhkb-WQ_-1CfodVX";
const db = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);


// 啟動 Service Worker，讓系統可以安裝成 App（PWA）
if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("sw.js");
}