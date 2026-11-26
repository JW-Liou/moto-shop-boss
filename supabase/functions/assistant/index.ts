// =====================================================================
// AI 小助理（放在 Supabase 的 Edge Function，名稱：assistant）
//
// 流程：
//   1. 網頁把對話送來，附上「登入員工的通行證」
//   2. 先確認這個人在員工名單上，不是就拒絕
//   3. 把問題交給 Google Gemini，Gemini 需要資料時會要求「查詢工具」
//   4. 查詢工具 = 資料庫的 assistant_tool 函式，用員工自己的權限去查（門禁照樣有效）
//   5. 想新增預約、工單時，小助理不會直接存，只會回傳「建議」，網頁上要按確認才存
//
// 需要的祕密設定（Supabase → Edge Functions → Secrets）：
//   GEMINI_API_KEY  在 Google AI Studio 申請的金鑰（只放這裡，絕對不要放進網頁）
//   GEMINI_MODEL    選填，想指定模型才設，例如 gemini-3.5-flash
// =====================================================================

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// 沒有指定模型時，依序試這幾個（Google 改名或下架時會自動換下一個）
const MODEL_CANDIDATES = ["gemini-flash-latest", "gemini-3.5-flash", "gemini-3.1-flash-lite", "gemini-flash-lite-latest"];

const MAX_ROUNDS = 6;          // 一個問題最多查幾輪資料
const MAX_MESSAGES = 16;       // 只帶最近 16 句對話
const MAX_TEXT = 1000;         // 每一句最多 1000 字

// ----- 小助理能用的工具 -----
const S = (description: string) => ({ type: "STRING", description });
const TOOLS = [
  {
    name: "day_overview",
    description: "某一天的概況：來客數、開了幾張工單、完成幾筆、營收、預約數、目前待修的數量。沒給日期就是今天。",
    parameters: { type: "OBJECT", properties: { date: S("日期 YYYY-MM-DD") } },
  },
  {
    name: "period_stats",
    description: "一段期間的來客數、完成筆數、營收、最常做的項目。例如本月、上個月、今年。",
    parameters: {
      type: "OBJECT",
      properties: { from: S("開始日期 YYYY-MM-DD"), to: S("結束日期 YYYY-MM-DD，沒給就是今天") },
      required: ["from"],
    },
  },
  {
    name: "find_bike",
    description: "用車牌查一台車：車型、車主姓名、最近的維修紀錄（日期、項目、零件、金額）、接下來的預約。車牌打不完整會回傳相似車牌。",
    parameters: { type: "OBJECT", properties: { plate: S("車牌，例如 ABC-1234") }, required: ["plate"] },
  },
  {
    name: "find_customer",
    description: "用姓名（可以只打一部分）找客戶，回傳他有哪些車、最後一次來店日期。沒有電話。",
    parameters: { type: "OBJECT", properties: { name: S("姓名或姓名的一部分") }, required: ["name"] },
  },
  {
    name: "list_appointments",
    description: "列出某一天或一段期間的預約（時間、車牌、姓名、項目、狀態、來源：店內／線上）。",
    parameters: { type: "OBJECT", properties: { from: S("開始日期，沒給就是今天"), to: S("結束日期，沒給就跟開始同一天") } },
  },
  {
    name: "list_work_orders",
    description: "列出工單看板上的工單。",
    parameters: {
      type: "OBJECT",
      properties: { status: { type: "STRING", enum: ["未完成", "今天完成"], description: "沒給就是未完成" } },
    },
  },
  {
    name: "stock_status",
    description: "查庫存：零件現在有幾個、安全庫存、售價、跟哪家廠商叫，還有已經叫貨但還沒到的單。",
    parameters: {
      type: "OBJECT",
      properties: {
        keyword: S("品名、規格或分類的關鍵字，例如 機油、輪胎；不給就列全部"),
        only_low: { type: "BOOLEAN", description: "只列要叫貨的（數量低於或等於安全庫存）" },
      },
    },
  },
  {
    name: "propose_appointment",
    description: "使用者想新增預約時用。不會直接存檔，會在畫面上顯示給使用者確認。",
    parameters: {
      type: "OBJECT",
      properties: {
        date: S("日期 YYYY-MM-DD"),
        time: S("時間 HH:MM，沒說就留空"),
        plate: S("車牌"),
        name: S("客人姓名"),
        items: S("要做的項目，例如 換機油"),
      },
      required: ["date"],
    },
  },
  {
    name: "propose_work_order",
    description: "使用者想新增工單（維修紀錄）時用。不會直接存檔，會在畫面上顯示給使用者確認。車輛要已經建檔。",
    parameters: {
      type: "OBJECT",
      properties: {
        plate: S("車牌"),
        items: S("維修項目，多個用「、」隔開"),
        parts: S("用了哪些零件"),
        total: { type: "INTEGER", description: "金額（元）" },
        mileage: { type: "INTEGER", description: "目前里程（公里）" },
        status: { type: "STRING", enum: ["已完成", "待修"], description: "沒說就是已完成；只有說「先放著」「還沒修」才是待修" },
      },
      required: ["plate", "items"],
    },
  },
];

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json; charset=utf-8" },
  });
}

// 台灣今天的日期和星期
function taiwanToday() {
  const now = new Date(Date.now() + 8 * 3600 * 1000);
  const date = now.toISOString().slice(0, 10);
  const week = "日一二三四五六"[now.getUTCDay()];
  const time = now.toISOString().slice(11, 16);
  return { date, week, time };
}

function systemPrompt() {
  const t = taiwanToday();
  return [
    "你是「竹北榮詮」機車行管理系統裡的小助理，幫老闆和店員查資料、整理數字、新增預約和工單。",
    `現在是台灣時間 ${t.date}（星期${t.week}）${t.time}。`,
    "規則：",
    "1. 一律用繁體中文、台灣用語回答，簡短清楚，像店裡的同事在講話。金額用「元」並加千分位。",
    "2. 跟店裡資料有關的問題，一定要先用工具查，不可以自己編數字或紀錄。查不到就說查不到。",
    "3. 「來客」的算法：同一台車同一天算一位。營收只算已完成的工單，以完成的那天為準。",
    "4. 你看不到客人的電話。有人問電話，請他到「客戶查詢」頁看。",
    "5. 要新增預約或工單時，用 propose_appointment 或 propose_work_order，然後跟使用者說「請在下面確認後存檔」，不可以說已經存好了。資料不夠（例如沒有日期、車牌、項目）先問清楚。",
    "6. 「明天」「下週一」這類說法，請換算成 YYYY-MM-DD 再用。",
    "7. 你不能刪除或修改任何資料，有人要求就請他到對應的頁面操作。",
    "8. 跟機車行無關的閒聊，簡短回應就好。",
  ].join("\n");
}

// 呼叫資料庫的 assistant_tool（用員工自己的通行證）
async function runTool(name: string, args: unknown, auth: string, apikey: string) {
  const url = Deno.env.get("SUPABASE_URL");
  const res = await fetch(`${url}/rest/v1/rpc/assistant_tool`, {
    method: "POST",
    headers: { apikey, Authorization: auth, "Content-Type": "application/json" },
    body: JSON.stringify({ p_name: name, p_args: args ?? {} }),
  });
  const body = await res.json().catch(() => null);
  if (!res.ok) return { error: body?.message || `查詢失敗（${res.status}）` };
  return body;
}

// 呼叫 Gemini
//   - 模型不存在（404）→ 換下一個
//   - Google 忙線（500、503…）→ 等一下再試一次，還是不行就換下一個模型
//   - 免費額度用完（429）→ 換下一個模型（每個模型的額度是分開算的）
//   - Google 太久沒回（超過 25 秒）→ 當作忙線，換下一個模型
// 找到能用的模型就記住，下次先用它
let workingModel = "";
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const GEMINI_TIMEOUT = 25_000;   // 每次問 Google 最多等 25 秒
const TOTAL_LIMIT = 100_000;     // 整個問題最多花 100 秒（Supabase 上限是 150 秒）
async function callGemini(contents: unknown[], key: string, startedAt: number) {
  const chosen = Deno.env.get("GEMINI_MODEL");
  const list = chosen ? [chosen, ...MODEL_CANDIDATES] : workingModel ? [workingModel, ...MODEL_CANDIDATES] : MODEL_CANDIDATES;
  const models = [...new Set(list)];
  let busy = false, quota = false, missing = 0;
  for (const model of models) {
    for (let attempt = 0; attempt < 2; attempt++) {
      const left = TOTAL_LIMIT - (Date.now() - startedAt);
      if (left < 5_000) throw new Error("Google 的 AI 回得太慢了，請過一兩分鐘再問一次。");
      const t0 = Date.now();
      let res: Response;
      try {
        res = await fetch(
          `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`,
          {
            method: "POST",
            headers: { "x-goog-api-key": key, "Content-Type": "application/json" },
            body: JSON.stringify({
              systemInstruction: { parts: [{ text: systemPrompt() }] },
              contents,
              tools: [{ functionDeclarations: TOOLS }],
              generationConfig: { temperature: 0.3 },
            }),
            signal: AbortSignal.timeout(Math.min(GEMINI_TIMEOUT, left)),
          },
        );
      } catch (e) {
        // 等太久被中斷，或連不上 Google：當作忙線，換下一個模型
        console.error(`Gemini ${model} 沒有回應（${Date.now() - t0} 毫秒）：${e instanceof Error ? e.name : e}`);
        busy = true;
        break;
      }
      if (res.ok) {
        console.log(`Gemini ${model} 成功（${Date.now() - t0} 毫秒）`);
        workingModel = model;
        return await res.json();
      }
      const text = await res.text();
      console.error(`Gemini ${model} 回應 ${res.status}：${text.slice(0, 300)}`);
      if (res.status === 404) { missing++; break; }
      if (res.status === 429) { quota = true; break; }
      if (res.status >= 500) {
        busy = true;
        if (attempt === 0) { await sleep(1500); continue; }
        break;
      }
      if (/API key/i.test(text)) throw new Error("AI 金鑰不正確，請到 Supabase 重新設定 GEMINI_API_KEY。");
      if (res.status === 403) throw new Error("AI 金鑰沒有權限，請確認 GEMINI_API_KEY 是在 Google AI Studio 申請的。");
      throw new Error(`AI 服務發生錯誤（${res.status}）`);
    }
  }
  if (busy) throw new Error("Google 的 AI 現在太多人在用（忙線中），請過一兩分鐘再問一次。");
  if (quota) throw new Error("AI 的免費額度暫時用完了（每分鐘或每天有上限），請等一下再問。");
  throw new Error(`AI 模型都無法使用（找不到 ${missing} 個模型），請到 Supabase 設定 GEMINI_MODEL。`);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "只接受 POST" }, 405);

  const startedAt = Date.now();
  try {
    // 1. 確認是員工
    const auth = req.headers.get("Authorization") ?? "";
    const apikey = req.headers.get("apikey") ?? Deno.env.get("SUPABASE_ANON_KEY") ?? "";
    if (!auth.startsWith("Bearer ")) return json({ error: "請先登入" }, 401);
    const staffRes = await fetch(`${Deno.env.get("SUPABASE_URL")}/rest/v1/staff?select=user_id&limit=1`, {
      headers: { apikey, Authorization: auth },
    });
    if (!staffRes.ok) return json({ error: "登入已過期，請重新登入" }, 401);
    const staff = await staffRes.json();
    if (!Array.isArray(staff) || staff.length === 0) return json({ error: "只有店內員工可以使用小助理" }, 403);

    const key = Deno.env.get("GEMINI_API_KEY");
    if (!key) return json({ error: "小助理還沒設定 AI 金鑰（GEMINI_API_KEY），請看設定說明。" }, 500);

    // 2. 整理對話
    const body = await req.json().catch(() => ({}));
    const messages = Array.isArray(body.messages) ? body.messages.slice(-MAX_MESSAGES) : [];
    const contents: any[] = messages
      .filter((m: any) => typeof m?.text === "string" && m.text.trim())
      .map((m: any) => ({
        role: m.role === "user" ? "user" : "model",
        parts: [{ text: m.text.slice(0, MAX_TEXT) }],
      }));
    if (!contents.length || contents[contents.length - 1].role !== "user") {
      return json({ error: "沒有收到問題" }, 400);
    }
    // Gemini 規定第一句要是使用者說的；連續兩句同一方說的，合成一句
    while (contents.length && contents[0].role !== "user") contents.shift();
    for (let i = contents.length - 1; i > 0; i--) {
      if (contents[i].role === contents[i - 1].role) {
        contents[i - 1].parts[0].text += "\n" + contents[i].parts[0].text;
        contents.splice(i, 1);
      }
    }

    // 3. 跟 Gemini 來回：它要查資料就幫它查，直到它給出回答
    const proposals: unknown[] = [];
    const used: string[] = [];
    for (let round = 0; round < MAX_ROUNDS; round++) {
      const data = await callGemini(contents, key, startedAt);
      const content = data?.candidates?.[0]?.content;
      const parts: any[] = content?.parts ?? [];
      const calls = parts.filter((p) => p.functionCall);

      if (!calls.length) {
        const reply = parts.filter((p) => p.text && !p.thought).map((p) => p.text).join("").trim();
        return json({ reply: reply || "（小助理沒有回答，請換個方式問問看）", proposals, used });
      }

      contents.push(content); // 原封不動放回去（Gemini 3 需要裡面的 thoughtSignature）
      const responses = [];
      for (const p of calls) {
        const { name, args, id } = p.functionCall;
        used.push(name);
        let result: unknown;
        if (name === "propose_appointment" || name === "propose_work_order") {
          proposals.push({ type: name === "propose_appointment" ? "appointment" : "work_order", args: args ?? {} });
          result = { status: "已顯示在畫面上，等使用者按確認才會存檔" };
        } else if (TOOLS.some((t) => t.name === name)) {
          result = await runTool(name, args, auth, apikey);
        } else {
          result = { error: "沒有這個工具" };
        }
        responses.push({ functionResponse: { name, ...(id ? { id } : {}), response: { result } } });
      }
      contents.push({ role: "user", parts: responses });
    }
    return json({ reply: "這個問題要查的東西太多了，請拆成小一點的問題再問一次。", proposals, used });
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 500);
  }
});
