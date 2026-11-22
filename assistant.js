// ===== AI 小助理（每一頁右下角的「小助理」按鈕） =====
// 問問題 → 送到 Supabase 的 assistant（Edge Function）→ 它用 Gemini 查資料後回答
// 想新增預約或工單時，小助理只會「提出建議」，要在這裡按「確認新增」才會真的存進資料庫

(function () {
  if (typeof db === "undefined") return;

  const STORE = "ai-chat";
  const SUGGESTIONS = ["今天狀況怎樣？", "有哪些零件要叫貨？", "這個月營收多少？", "明天有哪些預約？"];
  let history = [];
  try { history = JSON.parse(sessionStorage.getItem(STORE) || "[]"); } catch (e) { history = []; }
  let busy = false;

  // ----- 畫面 -----
  const fab = document.createElement("button");
  fab.className = "ai-fab";
  fab.type = "button";
  fab.innerHTML = '<span class="ai-dot"></span>小助理';
  fab.title = "AI 小助理：查資料、算數字、幫忙新增預約和工單";

  const panel = document.createElement("section");
  panel.className = "ai-panel";
  panel.hidden = true;
  panel.innerHTML = `
    <div class="ai-head">
      <b>AI 小助理</b>
      <span>
        <button type="button" class="ai-icon" data-act="clear" title="清除對話">清除</button>
        <button type="button" class="ai-icon" data-act="close" title="關閉（Esc）">✕</button>
      </span>
    </div>
    <div class="ai-body" id="aiBody"></div>
    <div class="ai-sugs" id="aiSugs"></div>
    <form class="ai-input" id="aiForm">
      <textarea id="aiText" rows="1" maxlength="500" placeholder="問店裡的事，例如：ABC-1234 上次換什麼？"></textarea>
      <button class="btn" type="submit">送出</button>
    </form>
    <p class="ai-note">使用 Google Gemini 免費版：問題和查到的資料（不含電話）會傳給 Google。新增資料前都會先讓你確認。</p>`;
  document.body.append(fab, panel);

  const body = panel.querySelector("#aiBody");
  const text = panel.querySelector("#aiText");

  function save() {
    try { sessionStorage.setItem(STORE, JSON.stringify(history.slice(-30))); } catch (e) { /* 存不了就算了 */ }
  }

  let rendered = false;
  function open() {
    panel.hidden = false;
    fab.hidden = true;
    if (!rendered) { render(); rendered = true; }
    text.focus();
  }
  function close() {
    panel.hidden = true;
    fab.hidden = false;
  }
  fab.onclick = open;
  panel.querySelector('[data-act="close"]').onclick = close;
  panel.querySelector('[data-act="clear"]').onclick = () => {
    history = [];
    save();
    render();
  };
  document.addEventListener("keydown", e => {
    if (e.key === "Escape" && !panel.hidden) close();
  });

  // 簡單排版：**粗體**、條列（* 或 - 開頭）
  function format(str) {
    const esc = str.replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
    return esc
      .replace(/\*\*(.+?)\*\*/g, "<b>$1</b>")
      .replace(/^\s*[*-]\s+/gm, "• ");
  }

  function bubble(role, html, extraClass) {
    const div = document.createElement("div");
    div.className = "ai-msg " + (role === "user" ? "me" : "bot") + (extraClass ? " " + extraClass : "");
    div.innerHTML = html;
    body.appendChild(div);
    body.scrollTop = body.scrollHeight;
    return div;
  }

  function render() {
    body.innerHTML = "";
    if (!history.length) {
      bubble("bot", "嗨！我可以幫你查今天的狀況、某台車的紀錄、庫存、營收，也可以幫忙新增預約和工單。");
    }
    history.forEach(m => bubble(m.role, format(m.text)));
    const sugs = panel.querySelector("#aiSugs");
    sugs.innerHTML = "";
    if (history.length === 0) {
      SUGGESTIONS.forEach(s => {
        const b = document.createElement("button");
        b.type = "button";
        b.textContent = s;
        b.onclick = () => ask(s);
        sugs.appendChild(b);
      });
    }
  }

  panel.querySelector("#aiForm").onsubmit = e => {
    e.preventDefault();
    ask(text.value);
  };
  text.addEventListener("keydown", e => {
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
      e.preventDefault();
      ask(text.value);
    }
  });

  async function ask(question) {
    question = (question || "").trim();
    if (!question || busy) return;
    busy = true;
    text.value = "";
    history.push({ role: "user", text: question });
    save();
    panel.querySelector("#aiSugs").innerHTML = "";
    const mine = bubble("user", format(question));
    const wait = bubble("bot", '<span class="ai-typing"><i></i><i></i><i></i></span> 查資料中…', "wait");

    let reply, proposals = [], failed = false;
    try {
      const { data, error } = await db.functions.invoke("assistant", { body: { messages: history } });
      if (error) {
        let msg = error.message;
        const status = error.context && error.context.status;
        try {
          msg = (await error.context.json()).error || msg;
        } catch (e) {
          // 不是小助理自己回的錯誤（例如 Supabase 判定執行太久被停掉）
          if (status === 546 || status === 504) msg = "小助理等 Google 回應等太久了，請過一下再問一次。";
          else if (status) msg = `小助理暫時無法使用（${status}），請過一下再試。`;
        }
        throw new Error(msg);
      }
      reply = data.reply;
      proposals = data.proposals || [];
    } catch (e) {
      failed = true;
      reply = "⚠ " + (/Failed to send|fetch/i.test(e.message)
        ? "連不到小助理，請確認網路，或小助理還沒安裝（看設定說明）。"
        : e.message);
    }
    wait.remove();
    if (failed) {
      history.pop(); // 失敗的問題不留在對話裡，方便重問
      mine.remove();
      text.value = question;
      save();
      bubble("bot", format(reply), "err");
    } else {
      history.push({ role: "assistant", text: reply });
      save();
      bubble("bot", format(reply));
      proposals.forEach(showProposal);
    }
    busy = false;
  }

  // ----- 新增預約／工單：先讓人確認 -----
  function field(label, name, value, type) {
    const v = value == null ? "" : String(value).replace(/"/g, "&quot;");
    return `<label>${label}<input name="${name}" type="${type || "text"}" value="${v}"></label>`;
  }

  function showProposal(p) {
    const a = p.args || {};
    const card = document.createElement("form");
    card.className = "ai-proposal";
    if (p.type === "appointment") {
      card.innerHTML = `<b>新增預約</b>
        <div class="ai-grid">
          ${field("日期", "date", a.date, "date")}
          ${field("時間", "time", a.time, "time")}
          ${field("車牌", "plate", a.plate)}
          ${field("姓名", "name", a.name)}
          ${field("項目", "items", a.items)}
        </div>`;
    } else {
      const st = ["待修", "維修中", "已完成"]
        .map(s => `<option ${s === (a.status || "待修") ? "selected" : ""}>${s}</option>`).join("");
      card.innerHTML = `<b>新增工單（日期：今天）</b>
        <div class="ai-grid">
          ${field("車牌", "plate", a.plate)}
          ${field("項目", "items", a.items)}
          ${field("零件", "parts", a.parts)}
          ${field("金額（元）", "total", a.total, "number")}
          ${field("里程（公里）", "mileage", a.mileage, "number")}
          <label>狀態<select name="status">${st}</select></label>
        </div>`;
    }
    card.insertAdjacentHTML("beforeend", `
      <p class="ai-result"></p>
      <div class="ai-actions">
        <button class="btn-small" type="submit">確認新增</button>
        <button class="btn-small btn-plain" type="button" data-act="drop">不要了</button>
      </div>`);
    card.querySelector('[data-act="drop"]').onclick = () => card.remove();
    card.onsubmit = async e => {
      e.preventDefault();
      const btn = card.querySelector('[type="submit"]');
      const out = card.querySelector(".ai-result");
      btn.disabled = true;
      out.textContent = "存檔中…";
      const f = Object.fromEntries(new FormData(card));
      try {
        const done = p.type === "appointment" ? await saveAppointment(f) : await saveWorkOrder(f);
        out.textContent = "✅ " + done;
        card.classList.add("saved");
        card.querySelectorAll("input, select, button").forEach(x => (x.disabled = true));
        history.push({ role: "assistant", text: "（使用者已確認：" + done + "）" });
        save();
      } catch (err) {
        out.textContent = "⚠ " + err.message;
        btn.disabled = false;
      }
    };
    body.appendChild(card);
    body.scrollTop = body.scrollHeight;
  }

  const plateOf = s => (s || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
  const todayStr = () => new Date().toLocaleDateString("sv-SE");

  async function findBike(plate) {
    const { data, error } = await db.from("bikes").select("*, customers(name, phone)").eq("plate", plate).maybeSingle();
    if (error) throw new Error("查詢車輛失敗：" + error.message);
    return data;
  }

  async function saveAppointment(f) {
    if (!f.date) throw new Error("請填日期");
    const plate = plateOf(f.plate);
    let name = (f.name || "").trim();
    let phone = "";
    if (!plate && !name) throw new Error("車牌和姓名至少填一個");
    if (plate) {
      const bike = await findBike(plate);
      if (bike && bike.customers) {
        if (!name) name = bike.customers.name || "";
        phone = bike.customers.phone || "";
      }
    }
    const { error } = await db.from("appointments").insert({
      date: f.date,
      time: f.time || null,
      plate: plate || null,
      name,
      phone,
      items: (f.items || "").trim(),
      source: "小助理"
    });
    if (error) throw new Error("新增預約失敗：" + error.message);
    if (typeof loadAppointments === "function") loadAppointments();
    return `已新增預約 ${f.date} ${f.time || ""} ${plate || name}`.replace(/\s+/g, " ").trim();
  }

  async function saveWorkOrder(f) {
    const plate = plateOf(f.plate);
    if (!plate) throw new Error("請填車牌");
    if (!(f.items || "").trim()) throw new Error("請填項目");
    const bike = await findBike(plate);
    if (!bike) throw new Error(`${plate} 還沒建檔，請先在工作看板的「車牌查詢」建檔`);
    const km = f.mileage ? Number(f.mileage) : null;
    // 里程怪怪的先問一下（AI 可能聽錯數字）
    if (km && km > 300000) throw new Error(`里程 ${km.toLocaleString()} 公里不太合理，請改一下`);
    if (km && bike.mileage && km < bike.mileage &&
        !confirm(`里程 ${km.toLocaleString()} 比這台車上次登記的 ${bike.mileage.toLocaleString()} 還少，確定嗎？`)) {
      throw new Error("已取消，請修改里程");
    }
    const { error } = await db.from("service_records").insert({
      bike_id: bike.id,
      date: todayStr(),
      mileage: km,
      items: f.items.trim(),
      parts: (f.parts || "").trim(),
      total: Number(f.total) || 0,
      status: f.status || "待修",
      completed_at: f.status === "已完成" ? new Date().toISOString() : null
    });
    if (error) throw new Error("新增工單失敗：" + error.message);
    if (km && km > (bike.mileage || 0)) {
      await db.from("bikes").update({ mileage: km }).eq("id", bike.id);
    }
    if (typeof loadDashboard === "function") loadDashboard();
    return `已新增工單 ${plate}：${f.items.trim()}`;
  }
})();
