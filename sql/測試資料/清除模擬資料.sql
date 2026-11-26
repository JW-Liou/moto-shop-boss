-- =====================================================================
-- 老闆版：清除全部模擬資料（交給老闆前一定要跑！）
-- 會清空：客戶、車輛、工單、預約、便條、操作紀錄、零件、廠商、叫貨單、庫存進出、
--         客人的 LINE 綁定、綁定碼、測試時關掉的預約時段、老闆專區的進價和支出、
--         先登記的零件進價、新車
-- 會保留：員工名單（老闆的登入帳號）、老闆密碼、每週固定時段、預約設定和店家資訊、資料表結構和門禁
-- ⚠ 開始放真實資料後就「不要」再執行這個檔案，會把真資料一起清掉
-- =====================================================================

truncate table public.service_records, public.bikes, public.customers,
               public.appointments, public.notes, public.activity_log
restart identity cascade;

-- 庫存的範例資料也清掉（還沒啟用庫存的話，這段會自動跳過）
do $$
begin
  if to_regclass('public.parts') is not null then
    truncate table public.stock_moves, public.purchase_order_items, public.purchase_orders,
                   public.parts, public.suppliers
    restart identity cascade;
  end if;
end $$;

-- 客人網站的測試資料也清掉（客人綁定、綁定碼會跟著客戶一起清空；這裡再清關掉的時段）
do $$
begin
  if to_regclass('public.booking_blocks') is not null then
    truncate table public.booking_blocks, public.bind_attempts restart identity;
    truncate table public.customer_accounts, public.bind_codes;
  end if;
end $$;

-- 老闆專區：測試時記的支出、刪掉的庫存紀錄（老闆密碼會保留；零件進價會跟著範例零件一起清掉）
do $$
begin
  if to_regclass('public.owner_expenses') is not null then
    truncate table public.owner_expenses, public.deleted_stock_moves restart identity;
  end if;
  if to_regclass('public.record_extras') is not null then
    truncate table public.record_extras, public.owner_supplier_payments restart identity;
  end if;
  -- 測試時先登記的「還沒進的零件」進價、目前登入中的老闆專區（密碼本身保留）
  if to_regclass('public.pending_costs') is not null then
    truncate table public.pending_costs restart identity;
  end if;
  if to_regclass('public.owner_sessions') is not null then
    truncate table public.owner_sessions;
  end if;
  -- 新車（跑過第 7 個 SQL 才有）
  if to_regclass('public.new_bikes') is not null then
    truncate table public.new_bike_costs, public.new_bikes restart identity cascade;
  end if;
end $$;

-- 確認：前 8 個都應該是 0，員工名單至少 1
select '客戶' as 資料, count(*) as 筆數 from public.customers
union all select '車輛', count(*) from public.bikes
union all select '工單', count(*) from public.service_records
union all select '預約', count(*) from public.appointments
union all select '便條', count(*) from public.notes
union all select '操作紀錄', count(*) from public.activity_log
union all select '零件', count(*) from public.parts
union all select '廠商', count(*) from public.suppliers
union all select '員工名單（要保留）', count(*) from public.staff;
