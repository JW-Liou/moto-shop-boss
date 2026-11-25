"""
每天自動備份（由 GitHub Actions 執行，不用自己跑）

做的事：
1. 用店家帳號登入 Supabase（跟在網頁上登入一樣，受 RLS 保護）
2. 把客戶、車輛、工單、預約、便條全部讀出來（一次 1000 筆，一頁一頁拿）
3. 存成跟「一鍵備份」一樣格式的 Excel
4. 用密碼加密壓縮成 .7z（因為 GitHub 上的備份檔別人也可能下載得到）

需要的設定（放在 GitHub 的 Secrets，不會出現在程式碼裡）：
  SHOP_EMAIL       店家登入用的 Email
  SHOP_PASSWORD    店家登入用的密碼
  BACKUP_PASSWORD  備份檔的解壓縮密碼（自己取一個長一點的）
"""
import datetime
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

from openpyxl import Workbook

TABLES = [
    ("customers", "客戶"),
    ("bikes", "車輛"),
    ("service_records", "工單"),
    ("appointments", "預約"),
    ("notes", "便條"),
    # 庫存（還沒啟用庫存的話會自動跳過）
    ("suppliers", "廠商"),
    ("parts", "零件"),
    ("purchase_orders", "叫貨單"),
    ("purchase_order_items", "叫貨明細"),
    ("stock_moves", "庫存進出"),
    # 線上預約時段（還沒啟用的話會自動跳過）
    ("booking_settings", "預約設定"),
    ("booking_slots", "預約時段"),
    ("booking_blocks", "關閉的時段"),
]
OPTIONAL = {"suppliers", "parts", "purchase_orders", "purchase_order_items", "stock_moves",
            "booking_settings", "booking_slots", "booking_blocks"}
PAGE = 1000
TAIPEI = datetime.timezone(datetime.timedelta(hours=8))


def read_config():
    """從 js/config.js 讀 Supabase 網址和公開金鑰，不用另外再設定一次"""
    text = Path(__file__).resolve().parent.parent.joinpath("js", "config.js").read_text(encoding="utf-8")
    url = re.search(r'SUPABASE_URL\s*=\s*"([^"]+)"', text).group(1).rstrip("/")
    key = re.search(r'SUPABASE_KEY\s*=\s*"([^"]+)"', text).group(1)
    return url, key


class HttpError(Exception):
    pass


def request(url, headers, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers=headers, method="POST" if body is not None else "GET")
    try:
        with urllib.request.urlopen(req, timeout=60) as res:
            return json.loads(res.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        raise HttpError(f"連線失敗（{e.code}）：{e.read().decode('utf-8', 'replace')[:300]}")


def login(url, key, email, password):
    try:
        res = request(f"{url}/auth/v1/token?grant_type=password",
                      {"apikey": key, "Content-Type": "application/json"},
                      {"email": email, "password": password})
    except HttpError as e:
        raise SystemExit(f"登入失敗：{e}")
    return res["access_token"]


def fetch_all(url, key, token, table):
    headers = {"apikey": key, "Authorization": f"Bearer {token}"}
    rows, offset = [], 0
    while True:
        page = request(f"{url}/rest/v1/{table}?select=*&order=id.asc&limit={PAGE}&offset={offset}", headers)
        rows.extend(page)
        if len(page) < PAGE:
            return rows
        offset += PAGE


def cell(v):
    """Excel 放不下的東西（清單、物件）轉成文字"""
    if isinstance(v, (dict, list)):
        return json.dumps(v, ensure_ascii=False)
    return v


def main():
    email = os.environ.get("SHOP_EMAIL")
    password = os.environ.get("SHOP_PASSWORD")
    zip_password = os.environ.get("BACKUP_PASSWORD")
    if not (email and password and zip_password):
        raise SystemExit("缺少設定：請在 GitHub 的 Settings → Secrets 加上 SHOP_EMAIL、SHOP_PASSWORD、BACKUP_PASSWORD")

    url, key = read_config()
    token = login(url, key, email, password)

    now = datetime.datetime.now(TAIPEI)
    book = Workbook()
    info = book.active
    info.title = "說明"
    info.append(["工作表", "資料表名稱", "筆數"])

    total = 0
    for table, sheet in TABLES:
        try:
            rows = fetch_all(url, key, token, table)
        except HttpError as e:
            if table in OPTIONAL:
                print(f"{sheet}：還沒啟用，跳過")
                continue
            raise SystemExit(f"讀取「{sheet}」失敗：{e}")
        total += len(rows)
        ws = book.create_sheet(sheet)
        columns = list(rows[0].keys()) if rows else ["（沒有資料）"]
        ws.append(columns)
        for r in rows:
            ws.append([cell(r.get(c)) for c in columns])
        info.append([sheet, table, len(rows)])
        print(f"{sheet}：{len(rows)} 筆")   # 只印筆數，不印內容

    info.append([])
    info.append(["備份時間", now.strftime("%Y/%m/%d %H:%M:%S")])
    info.append(["注意", "這是系統的完整備份（自動），請不要修改裡面的內容，需要還原時再拿出來用"])

    if total == 0:
        raise SystemExit("一筆資料都沒讀到，可能是帳號不在員工名單上，備份中止")

    out = Path("backup")
    out.mkdir(exist_ok=True)
    stamp = now.strftime("%Y-%m-%d_%H%M")
    xlsx = out / f"自動備份_{stamp}.xlsx"
    book.save(xlsx)

    # 加密壓縮：-mhe=on 連檔名都加密
    archive = out / f"自動備份_{stamp}.7z"
    subprocess.run(["7z", "a", "-t7z", f"-p{zip_password}", "-mhe=on", str(archive), str(xlsx)],
                   check=True, stdout=subprocess.DEVNULL)
    xlsx.unlink()  # 沒加密的 Excel 不留
    print(f"完成：{archive.name}（共 {total} 筆）")


if __name__ == "__main__":
    sys.exit(main())
