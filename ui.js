// ===== 共用的畫面效果（每一頁都會載入） =====
// 1. 上方導覽列：目前所在的頁面按鈕亮起來
// 2. 統計數字（.stat .num）改變時，用「跳動數字」的動畫顯示

(function () {
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // ----- 1. 標出目前的頁面 -----
  const page = location.pathname.split("/").pop() || "app.html";
  document.querySelectorAll(".topbar .user button").forEach(btn => {
    const target = (btn.getAttribute("onclick") || "").match(/location\.href='([^']+)'/);
    if (target && target[1] === page) btn.classList.add("active");
  });

  // ----- 2. 數字跳動 -----
  // 只處理「$1,234」「12」「12 台」這種格式，其他文字直接顯示
  const pattern = /^(\$?)([\d,]+)(\D*)$/;

  function animate(node, from, to, prefix, suffix) {
    const start = performance.now();
    const duration = 600;
    function frame(now) {
      const p = Math.min(1, (now - start) / duration);
      const eased = 1 - Math.pow(1 - p, 3);                 // 先快後慢
      const value = Math.round(from + (to - from) * eased);
      const text = prefix + value.toLocaleString() + suffix;
      node._uiFrame = text;                                  // 記住是自己改的，避免觸發自己
      node.textContent = text;
      if (p < 1) requestAnimationFrame(frame);
    }
    requestAnimationFrame(frame);
  }

  function handle(node) {
    const text = node.textContent.trim();
    if (text === node._uiFrame) return;                     // 動畫自己寫的字，不理它
    const m = text.match(pattern);
    if (!m) return;
    const to = Number(m[2].replace(/,/g, ""));
    const from = node._uiValue ?? 0;
    node._uiValue = to;
    if (reduceMotion || from === to) return;
    animate(node, from, to, m[1], m[3]);
  }

  const observer = new MutationObserver(list => {
    const seen = new Set();
    list.forEach(rec => {
      const node = rec.target.nodeType === 3 ? rec.target.parentElement : rec.target;
      const num = node && node.closest && node.closest(".stat .num");
      if (num && !seen.has(num)) { seen.add(num); handle(num); }
    });
  });
  observer.observe(document.body, { subtree: true, childList: true, characterData: true });
})();
