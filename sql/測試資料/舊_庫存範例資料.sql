-- =====================================================================
-- 老闆版：庫存範例資料（測試用，廠商和零件都是虛構的）
-- 要先跑過「sql/2_庫存.sql」
-- 內容：4 家廠商、30 種零件、最近一個月的進出紀錄、1 張已到貨和 1 張還沒到的叫貨單
-- 會故意讓幾樣東西低於安全庫存，方便測試「叫貨」
-- 清除：「sql/測試資料/清除模擬資料.sql」會一起清掉
-- =====================================================================

-- 灌範例資料時先不記操作紀錄
alter table public.parts     disable trigger log_changes;
alter table public.suppliers disable trigger log_changes;

do $$
declare
  s_oil bigint; s_tire bigint; s_parts bigint; s_batt bigint;
  p record; o1 bigint; o2 bigint;
  today date := (now() at time zone 'Asia/Taipei')::date;
  d date; n int; i int; rid bigint;
begin
  perform setseed(0.777);

  insert into public.suppliers (name, phone, line_id, note) values ('大成機油行（模擬）', '03-555-0101', 'dacheng-oil', '模擬資料：每週二、五送貨') returning id into s_oil;
  insert into public.suppliers (name, phone, line_id, note) values ('順發輪胎（模擬）', '03-555-0202', 'shunfa-tire', '模擬資料：隔天到') returning id into s_tire;
  insert into public.suppliers (name, phone, line_id, note) values ('竹北零件批發（模擬）', '03-555-0303', 'zb-parts', '模擬資料：下午 3 點前叫，當天到') returning id into s_parts;
  insert into public.suppliers (name, phone, line_id, note) values ('永光電池（模擬）', '03-555-0404', null, '模擬資料：只接電話') returning id into s_batt;

  insert into public.parts (name, spec, category, unit, safety_stock, price, supplier_id, note) values
    ('機油', '全合成 10W-40 1L',   '機油',   '瓶', 12, 450, s_oil,   '模擬資料'),
    ('機油', '半合成 10W-30 0.8L', '機油',   '瓶', 15, 300, s_oil,   '模擬資料'),
    ('機油', '礦物油 10W-30 0.8L', '機油',   '瓶', 10, 220, s_oil,   '模擬資料'),
    ('齒輪油', '80W-90 120ml',     '齒輪油', '瓶', 15, 150, s_oil,   '模擬資料'),
    ('煞車油', 'DOT4 500ml',       '煞車',   '瓶',  4, 300, s_oil,   '模擬資料'),
    ('空濾', '勁戰六代',           '濾網',   '個',  4, 300, s_parts, '模擬資料'),
    ('空濾', 'JET SL',             '濾網',   '個',  3, 300, s_parts, '模擬資料'),
    ('空濾', 'DRG',                '濾網',   '個',  3, 350, s_parts, '模擬資料'),
    ('空濾', 'Many 110',           '濾網',   '個',  3, 250, s_parts, '模擬資料'),
    ('空濾', 'BWS',                '濾網',   '個',  2, 300, s_parts, '模擬資料'),
    ('火星塞', 'CR7HSA',           '點火',   '顆',  6, 150, s_parts, '模擬資料'),
    ('火星塞', 'CR8E',             '點火',   '顆',  6, 250, s_parts, '模擬資料'),
    ('煞車皮', '前碟 通用',        '煞車',   '組',  5, 500, s_parts, '模擬資料'),
    ('煞車皮', '後鼓 通用',        '煞車',   '組',  4, 400, s_parts, '模擬資料'),
    ('皮帶', '勁戰六代',           '傳動',   '條',  2, 900, s_parts, '模擬資料'),
    ('皮帶', 'JET SL',             '傳動',   '條',  2, 900, s_parts, '模擬資料'),
    ('皮帶', 'Many 110',           '傳動',   '條',  2, 700, s_parts, '模擬資料'),
    ('普利珠', '13g',              '傳動',   '組',  3, 400, s_parts, '模擬資料'),
    ('普利珠', '14g',              '傳動',   '組',  3, 400, s_parts, '模擬資料'),
    ('燈泡', 'H4 大燈',            '電系',   '顆',  4, 250, s_parts, '模擬資料'),
    ('燈泡', 'T10 方向燈',         '電系',   '顆', 10,  50, s_parts, '模擬資料'),
    ('輪胎', '110/70-12',          '輪胎',   '條',  4, 1600, s_tire, '模擬資料'),
    ('輪胎', '120/70-12',          '輪胎',   '條',  4, 1700, s_tire, '模擬資料'),
    ('輪胎', '90/90-10',           '輪胎',   '條',  3, 1200, s_tire, '模擬資料'),
    ('輪胎', '100/90-10',          '輪胎',   '條',  3, 1300, s_tire, '模擬資料'),
    ('內胎', '10 吋',              '輪胎',   '條',  4, 250, s_tire,  '模擬資料'),
    ('電瓶', '7 號（YTX7A）',      '電系',   '顆',  3, 1300, s_batt, '模擬資料'),
    ('電瓶', '5 號（YTX5L）',      '電系',   '顆',  2, 1100, s_batt, '模擬資料'),
    ('電瓶', '9 號（YTX9）',       '電系',   '顆',  1, 1600, s_batt, '模擬資料'),
    ('雨刷水箱精', '1L',           '其他',   '瓶',  0, 120, null,    '模擬資料：很少用，不設安全庫存')
  on conflict do nothing;

  -- 一個月前盤點的期初數量（大約是安全庫存的 1.5～3 倍）
  for p in select id, safety_stock from public.parts where note like '模擬資料%' loop
    insert into public.stock_moves (part_id, change, reason, note, created_at)
    values (p.id, greatest(2, round(p.safety_stock * (1.5 + random() * 1.5))::int) + 2, '期初', '開始用系統時盤點',
            ((today - 30)::timestamp + interval '9 hours') at time zone 'Asia/Taipei');
  end loop;

  -- 這個月每天用掉一些（常用的機油、齒輪油用比較多）
  for d in select generate_series(today - 29, today, interval '1 day')::date loop
    continue when extract(dow from d) = 0;
    n := 2 + floor(random() * 5)::int;
    for i in 1..n loop
      select id, safety_stock into p from public.parts
      where note like '模擬資料%' and safety_stock > 0
      order by random() * (case when category in ('機油', '齒輪油') then 0.3 else 1 end) limit 1;
      -- 盡量接到那天真的工單上
      select id into rid from public.service_records where date = d order by random() limit 1;
      insert into public.stock_moves (part_id, change, reason, record_id, note, created_at)
      values (p.id, -1, '工單使用', rid, null,
              (d + make_interval(hours => 10 + floor(random() * 8)::int)) at time zone 'Asia/Taipei');
    end loop;
  end loop;

  -- 上週叫過一次機油，已經到貨
  insert into public.purchase_orders (supplier_id, status, note, created_at, received_at)
  values (s_oil, '已到貨', '模擬資料', now() - interval '8 days', now() - interval '7 days')
  returning id into o1;
  insert into public.purchase_order_items (order_id, part_id, qty)
  select o1, id, 12 from public.parts where note like '模擬資料%' and name = '機油' and spec like '半合成%';
  insert into public.stock_moves (part_id, change, reason, order_id, note, created_at)
  select part_id, qty, '進貨', o1, '叫貨單 #' || o1 || ' 到貨', now() - interval '7 days'
  from public.purchase_order_items where order_id = o1;

  -- 昨天叫了輪胎，還沒到
  insert into public.purchase_orders (supplier_id, status, note, created_at)
  values (s_tire, '已叫貨', '模擬資料', now() - interval '1 day')
  returning id into o2;
  insert into public.purchase_order_items (order_id, part_id, qty)
  select o2, id, 4 from public.parts where note like '模擬資料%' and name = '輪胎' and spec in ('110/70-12', '90/90-10');

  -- 故意讓幾樣低於安全庫存，方便測試叫貨
  insert into public.stock_moves (part_id, change, reason, note, created_at)
  select id, -(stock - safety_stock + 1), '盤點調整', '模擬資料：盤點發現少了', now() - interval '2 hours'
  from public.parts
  where note like '模擬資料%' and stock > safety_stock
    and (name, coalesce(spec, '')) in (('空濾', '勁戰六代'), ('火星塞', 'CR7HSA'), ('電瓶', '7 號（YTX7A）'), ('皮帶', 'JET SL'), ('齒輪油', '80W-90 120ml'));
end $$;

alter table public.parts     enable trigger log_changes;
alter table public.suppliers enable trigger log_changes;

-- 看看結果
select count(*) as 零件種類,
       count(*) filter (where stock <= safety_stock and safety_stock > 0) as 要叫貨,
       sum(stock) as 總件數
from public.parts;
