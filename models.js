// ===== 車型選單：點車型欄位，跳出熱門車款（依廠牌或排氣量分類），冷門的再自己打 =====
// 用法：在 <input> 加上 data-model-picker，載入這個檔案就好
// 想新增車款：在下面 MODELS 對應的廠牌、排氣量裡加一個名字

(function () {
  // 廠牌 → 排氣量分類 → 車款
  // 名字盡量跟店裡零件的「規格」寫法一樣（例如「勁戰六代」「JET SL」），選零件時才對得上車型
  const MODELS = {
    "山葉 YAMAHA": {
      "125": ["勁戰六代", "勁戰七代", "勁戰五代", "勁戰四代", "BWS", "BWS'R", "LIMI", "JOG", "RS NEO", "Vinoora"],
      "150～180": ["FORCE 2.0", "FORCE", "NMAX", "AUGUR", "SMAX"],
      "250 以上": ["XMAX 300", "TMAX 560"],
      "打檔車": ["MT-15", "R15", "XSR155", "R3"]
    },
    "三陽 SYM": {
      "100～115": ["WOO 115", "Mio 115"],
      "125": ["JET SL", "JETS", "JET SR", "迪爵 125", "全新迪爵 125", "4MICA 125", "CLBCU", "VIVO 活力", "FNX", "Z1 attila", "GT 125"],
      "150～180": ["DRG", "DRG 2", "MMBCU", "JET SL+ 158", "4MICA 150", "FIDDLE 150"],
      "250 以上": ["Maxsym TL 500", "Joymax Z300"],
      "打檔車": ["野狼傳奇 125", "WOLF 125"]
    },
    "光陽 KYMCO": {
      "100～115": ["Many 110", "Nice 100"],
      "125": ["新名流", "大地名流", "GP 125", "Racing S 125", "雷霆S 125", "LIKE 125", "金牌 125", "VJR 125", "豪邁 125", "Many 125"],
      "150～180": ["KRV", "KRV MOTO", "Racing King 180", "雷霆S 150", "G6 150", "Racing S 150", "Roma GT"],
      "250 以上": ["DTX 360", "AK 550", "Xciting VS 400"],
      "打檔車": ["KTR 150", "Kpipe 125"],
      "電動": ["i-One", "Many 110 EV"]
    },
    "台鈴 SUZUKI": {
      "100～115": ["Address 110", "NEX 115"],
      "125": ["Swish 125", "Saluto 125", "Burgman Street 125"],
      "打檔車": ["GSX-R150", "GSX-S150", "Gixxer 250"]
    },
    "宏佳騰 AEON": {
      "電動": ["Ai-1", "Ai-1 Sport", "Ai-1 Ultra", "Ai-3"]
    },
    "PGO 摩特動力": {
      "100～115": ["J-BUBU 115"],
      "125": ["J-BUBU 125", "Tigra 125", "Alpha Max 125", "My Bubu"],
      "150～180": ["Tigra 200"]
    },
    "Gogoro": {
      "電動": ["Gogoro VIVA", "Gogoro VIVA MIX", "Gogoro VIVA XL", "Gogoro 2", "Gogoro 3", "Gogoro S2", "Gogoro SuperSport", "Gogoro CrossOver", "Gogoro JEGO", "Gogoro Pulse", "Gogoro Delight"]
    },
    "本田 HONDA": {
      "150～180": ["PCX 160", "Vario 160", "ADV 160"],
      "250 以上": ["Forza 350", "ADV 350"],
      "打檔車": ["CB150R", "CBR150R", "Super Cub 110"]
    },
    "偉士牌 Vespa": {
      "125": ["Primavera 125", "Sprint 125"],
      "150～180": ["Primavera 150", "Sprint 150"],
      "250 以上": ["GTS 300"]
    }
  };
  const CC_ORDER = ["50 以下", "100～115", "125", "150～180", "250 以上", "打檔車", "電動"];

  // 全部攤平：[{ name, brand, cc }]
  const ALL = [];
  Object.entries(MODELS).forEach(([brand, groups]) =>
    Object.entries(groups).forEach(([cc, list]) => list.forEach(name => ALL.push({ name, brand, cc }))));

  const norm = s => (s || "").toLowerCase().replace(/[\s\-_'’]/g, "");

  // ----- 畫面（整個頁面共用一個） -----
  let panel, target, mode = "brand", active = null, shopTop = null;

  function el(tag, cls, text) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined) e.textContent = text;
    return e;
  }

  function build() {
    panel = el("div", "mp-overlay");
    panel.hidden = true;
    panel.innerHTML = `
      <div class="mp-box" role="dialog" aria-label="選車型">
        <div class="mp-head">
          <b>選車型</b>
          <div class="mp-mode">
            <button type="button" data-mode="brand" class="on">依廠牌</button>
            <button type="button" data-mode="cc">依排氣量</button>
          </div>
          <button type="button" class="mp-x" title="關閉（Esc）">✕</button>
        </div>
        <input class="mp-search" placeholder="搜尋車款，例如：勁戰、JET、Gogoro">
        <div class="mp-top"></div>
        <div class="mp-tabs"></div>
        <div class="mp-list"></div>
        <div class="mp-foot">
          <span>找不到？</span>
          <button type="button" class="btn-small mp-manual">自己輸入</button>
        </div>
      </div>`;
    document.body.appendChild(panel);
    panel.addEventListener("click", e => { if (e.target === panel) close(); });
    panel.querySelector(".mp-x").onclick = () => close();
    panel.querySelector(".mp-manual").onclick = () => close(true);
    panel.querySelectorAll(".mp-mode button").forEach(b => (b.onclick = () => {
      mode = b.dataset.mode;
      active = null;
      panel.querySelectorAll(".mp-mode button").forEach(x => x.classList.toggle("on", x === b));
      render();
    }));
    panel.querySelector(".mp-search").addEventListener("input", render);
    document.addEventListener("keydown", e => { if (e.key === "Escape" && panel && !panel.hidden) close(); });
  }

  // 店裡最常見的車型（從車輛資料算，給「最常見」那排按鈕用）
  async function loadShopTop() {
    if (shopTop || typeof db === "undefined") return;
    shopTop = [];
    const { data } = await db.from("bikes").select("model").limit(2000);
    if (!data) return;
    const count = {};
    data.forEach(b => { const m = (b.model || "").trim(); if (m) count[m] = (count[m] || 0) + 1; });
    shopTop = Object.entries(count).sort((a, b) => b[1] - a[1]).slice(0, 10).map(x => x[0]);
    if (panel && !panel.hidden) render();
  }

  function chip(name, sub) {
    const b = el("button", "mp-chip");
    b.type = "button";
    b.append(name);
    if (sub) b.appendChild(el("small", "", sub));
    b.onclick = () => pick(name);
    return b;
  }

  function render() {
    const q = norm(panel.querySelector(".mp-search").value);
    const tabs = panel.querySelector(".mp-tabs");
    const list = panel.querySelector(".mp-list");
    const top = panel.querySelector(".mp-top");
    tabs.innerHTML = ""; list.innerHTML = ""; top.innerHTML = "";

    // 搜尋：直接列出符合的
    if (q) {
      tabs.hidden = true; top.hidden = true;
      const hits = ALL.filter(m => norm(m.name).includes(q) || norm(m.brand).includes(q));
      if (!hits.length) {
        list.appendChild(el("p", "mp-empty", "沒有找到，按下面「自己輸入」就好"));
        const raw = panel.querySelector(".mp-search").value.trim();
        if (raw) {
          const use = el("button", "btn-small", `就用「${raw}」`);
          use.type = "button";
          use.onclick = () => pick(raw);
          list.appendChild(use);
        }
        return;
      }
      const wrap = el("div", "mp-chips");
      hits.slice(0, 60).forEach(m => wrap.appendChild(chip(m.name, m.brand.split(" ")[0] + "・" + m.cc)));
      list.appendChild(wrap);
      return;
    }
    tabs.hidden = false;

    // 店裡最常見
    if (shopTop && shopTop.length) {
      top.hidden = false;
      top.appendChild(el("div", "mp-label", "店裡最常見"));
      const wrap = el("div", "mp-chips");
      shopTop.forEach(n => wrap.appendChild(chip(n)));
      top.appendChild(wrap);
    } else top.hidden = true;

    // 分頁：廠牌或排氣量
    const keys = mode === "brand" ? Object.keys(MODELS) : CC_ORDER.filter(cc => ALL.some(m => m.cc === cc));
    if (!active || !keys.includes(active)) active = keys[0];
    keys.forEach(k => {
      const b = el("button", "mp-tab" + (k === active ? " on" : ""), mode === "cc" && /^\d/.test(k) ? k + " cc" : k);
      b.type = "button";
      b.onclick = () => { active = k; render(); };
      tabs.appendChild(b);
    });

    // 內容：依廠牌 → 再分排氣量；依排氣量 → 再分廠牌
    const groups = {};
    ALL.filter(m => (mode === "brand" ? m.brand : m.cc) === active).forEach(m => {
      const g = mode === "brand" ? m.cc : m.brand;
      (groups[g] ||= []).push(m.name);
    });
    const order = mode === "brand" ? CC_ORDER.filter(c => groups[c]) : Object.keys(groups);
    order.forEach(g => {
      list.appendChild(el("div", "mp-label", mode === "brand" && /^\d/.test(g) ? g + " cc" : g));
      const wrap = el("div", "mp-chips");
      groups[g].forEach(n => wrap.appendChild(chip(n)));
      list.appendChild(wrap);
    });
  }

  function open(input) {
    if (!panel) build();
    target = input;
    panel.querySelector(".mp-search").value = "";
    panel.hidden = false;
    render();
    loadShopTop();
    // 電腦上直接可以打字搜尋；手機不自動跳鍵盤
    if (window.matchMedia("(pointer: fine)").matches) panel.querySelector(".mp-search").focus();
  }

  function close(manual) {
    panel.hidden = true;
    if (manual && target) {
      target.dataset.mpManual = "1";   // 這次自己打，點欄位不要再跳選單
      target.focus();
    }
  }

  function pick(name) {
    target.value = name;
    target.dispatchEvent(new Event("input", { bubbles: true }));
    target.dispatchEvent(new Event("change", { bubbles: true }));
    close();
    // 跳到下一個欄位（年份）
    const fields = [...document.querySelectorAll("input, select, textarea")].filter(x => !x.disabled && x.offsetParent);
    const next = fields[fields.indexOf(target) + 1];
    if (next) next.focus();
  }

  // ----- 接到欄位上 -----
  function attach(input) {
    if (input.dataset.mpReady) return;
    input.dataset.mpReady = "1";
    input.setAttribute("autocomplete", "off");
    // 欄位旁邊的「選車型」按鈕
    const btn = el("button", "mp-open", "選車型");
    btn.type = "button";
    btn.title = "從熱門車款裡選";
    btn.onclick = () => { delete input.dataset.mpManual; open(input); };
    const wrap = el("span", "mp-field");
    input.parentNode.insertBefore(wrap, input);
    wrap.append(input, btn);
    // 欄位是空的時候，點一下就打開選單（按了「自己輸入」之後就不再自動打開）
    input.addEventListener("click", () => {
      if (!input.value.trim() && !input.dataset.mpManual) open(input);
    });
  }

  function attachAll() {
    document.querySelectorAll("input[data-model-picker]").forEach(attach);
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", attachAll);
  else attachAll();

  window.ModelPicker = { attach, open, MODELS };
})();
