-- =====================================================================
-- 8. 排氣定檢資料（從環境部「機車排氣檢驗資料查詢」抓回來的車籍資料）
--
-- 車輛多存這幾個欄位：
--   brand            廠牌（例如 山葉）
--   cc               排氣量
--   made_ym          出廠年月，6 碼，例如 202004
--   license_date     發照日期（每年的定檢月份就是看這個）
--   last_check_date  最近一次排氣定檢的日期
--   check_synced_at  上次去環境部網站查的時間
--
-- 規定：出廠滿 5 年的燃油機車，每年在「發照月份的前後 1 個月」內要定檢。
-- 可以重複執行。
-- =====================================================================

alter table public.bikes
  add column if not exists brand           text,
  add column if not exists cc              int,
  add column if not exists made_ym         text,
  add column if not exists license_date    date,
  add column if not exists last_check_date date,
  add column if not exists check_synced_at timestamptz;

comment on column public.bikes.brand           is '廠牌（環境部車籍資料）';
comment on column public.bikes.cc              is '排氣量';
comment on column public.bikes.made_ym         is '出廠年月 YYYYMM';
comment on column public.bikes.license_date    is '發照日期，定檢月份依這個算';
comment on column public.bikes.last_check_date is '最近一次排氣定檢日期';
comment on column public.bikes.check_synced_at is '上次查環境部網站的時間';

-- 檢查：應該看到 6 個欄位
select column_name from information_schema.columns
where table_schema = 'public' and table_name = 'bikes'
  and column_name in ('brand', 'cc', 'made_ym', 'license_date', 'last_check_date', 'check_synced_at');
