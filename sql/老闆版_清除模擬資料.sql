-- =====================================================================
-- 老闆版：清除全部模擬資料（交給老闆前一定要跑！）
-- 會清空：客戶、車輛、工單、預約、便條、操作紀錄、零件、廠商、叫貨單、庫存進出
-- 會保留：員工名單（老闆的登入帳號）、資料表結構和門禁
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

-- 確認：前 6 個都應該是 0，員工名單至少 1
select '客戶' as 資料, count(*) as 筆數 from public.customers
union all select '車輛', count(*) from public.bikes
union all select '工單', count(*) from public.service_records
union all select '預約', count(*) from public.appointments
union all select '便條', count(*) from public.notes
union all select '操作紀錄', count(*) from public.activity_log
union all select '員工名單（要保留）', count(*) from public.staff;
