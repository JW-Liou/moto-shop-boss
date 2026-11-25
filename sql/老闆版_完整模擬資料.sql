-- =====================================================================
-- 老闆版：完整模擬資料（兩年份，測試所有功能用）
--
-- 要先跑過所有老闆版的 SQL（全新資料庫、庫存、客端與小助理、老闆專區與改進、老闆專區第二批）
--
-- 會先「清空」現在的客戶、車輛、工單、預約、庫存、老闆專區資料，再放進新的模擬資料。
-- 會保留：員工帳號、老闆密碼、預約時段設定。
--
-- 內容（日期都是從「今天」往前推兩年，隨時跑都是最新的）：
--   客戶 500 位、車輛約 550 台、工單約 7,000 張（第二年生意比第一年好一點，有淡旺季、春節休息）
--   4 家廠商、30 種零件（都有進價，中間有一次機油漲價）、每週叫貨到貨、工單自動扣庫存
--   車禍維修的代工、臨時零件（有成本）、客人自備機油
--   預約：到店、取消、沒來、線上預約（有幾筆還沒看的新消息）、過期沒處理的
--   老闆專區：每月房租、水電、薪資、雜支，廠商付款紀錄
--   最後做幾個修改、刪除，讓「操作紀錄」和「垃圾桶」有東西看
--
-- ⚠ 只能在測試時用！放了真實資料後絕對不要跑（開頭有檢查，看到真實客戶會停下來）
-- ⚠ 交給老闆前，執行「老闆版_清除模擬資料.sql」清乾淨
-- 資料量比較大，Supabase 跑大概要 1～3 分鐘，請耐心等。
-- =====================================================================


-- ---------------------------------------------------------------------
-- 全部放在同一段裡：任何一步出錯（例如安全檢查不通過），整段都不會執行，資料不會被動到
-- ---------------------------------------------------------------------
do $$
declare
  surnames text[] := array['陳','林','黃','張','李','王','吳','劉','蔡','楊','許','鄭','謝','郭','洪','曾','邱','廖','賴','周','徐','蘇','葉','莊','呂'];
  givens   text[] := array['志明','雅婷','家豪','怡君','冠宇','淑芬','俊傑','美玲','建宏','佩珊','宗翰','欣怡','承恩','柏翰','思妤','子晴','宇軒','品妍','家瑜','睿恩'];
  models   text[] := array['勁戰六代','JET SL','DRG','MMBCU','Many 110','Gogoro VIVA','BWS','KRV','FORCE 2.0','迪爵 125','JETS','新名流'];
  -- 常用項目、出現機率、工錢
  item_names text[]    := array['機油','齒輪油','空濾','火星塞','煞車皮','煞車油','輪胎','皮帶','普利珠','電瓶'];
  item_odds  numeric[] := array[0.85,  0.55,   0.22,  0.14,    0.12,    0.06,    0.09,  0.05,  0.05,    0.05];

  today     date := (now() at time zone 'Asia/Taipei')::date;
  now_hour  int  := extract(hour from now() at time zone 'Asia/Taipei')::int;
  first_day date := (now() at time zone 'Asia/Taipei')::date - 729;
  cny1 date; cny2 date;   -- 兩次春節

  s_oil bigint; s_tire bigint; s_parts bigint; s_batt bigint;
  d date; n int; i int; k int; q int; cnt int; last_hour int;
  cid bigint; bid bigint; rid bigint; v_oid bigint; new_plate text;
  b record; pr record; sp record;
  its text[]; its2 text[]; labels text[]; v_total int; labor int; km int;
  opened timestamp; hrs numeric; r numeric; busy numeric; growth numeric;
  st text; done_at timestamptz; used_at timestamptz;
  pid bigint; spec_want text; m date;
  extra_kind text; extra_name text; extra_sale int; extra_cost int;
  oil_raised boolean := false;
  real_cnt int;
begin
  -- ===== 0. 安全檢查：有很多不是模擬的客戶，就停下來不要跑 =====
  select count(*) into real_cnt from public.customers where coalesce(note, '') not like '%模擬%';
  if real_cnt > 20 then
    raise exception '資料庫裡有 % 位不是模擬資料的客戶，看起來已經有真實資料了，所以停下來沒有執行。', real_cnt;
  end if;

  -- ===== 1. 清空舊資料（員工、老闆密碼、預約時段設定會保留） =====
  truncate table public.service_records, public.bikes, public.customers,
                 public.appointments, public.notes, public.activity_log,
                 public.stock_moves, public.purchase_order_items, public.purchase_orders,
                 public.parts, public.suppliers,
                 public.booking_blocks, public.bind_attempts, public.customer_accounts, public.bind_codes,
                 public.owner_expenses, public.deleted_stock_moves, public.record_extras,
                 public.owner_supplier_payments, public.owner_sessions
  restart identity cascade;

  -- 灌資料時不記操作紀錄（不然會有幾萬筆「新增」）
  alter table public.customers       disable trigger log_changes;
  alter table public.bikes           disable trigger log_changes;
  alter table public.service_records disable trigger log_changes;
  alter table public.appointments    disable trigger log_changes;
  alter table public.parts           disable trigger log_changes;
  alter table public.suppliers       disable trigger log_changes;

  -- ===== 2. 產生資料 =====
  perform setseed(0.2468);
  cny1 := make_date(extract(year from first_day)::int + 1, 2, 10);
  cny2 := make_date(extract(year from first_day)::int + 2, 2, 10);

  -- ===== 廠商、零件、進價 =====
  insert into public.suppliers (name, phone, line_id, note, created_at) values ('大成機油行（模擬）', '03-555-0101', 'dacheng-oil', '模擬資料：每週二、五送貨', first_day) returning id into s_oil;
  insert into public.suppliers (name, phone, line_id, note, created_at) values ('順發輪胎（模擬）', '03-555-0202', 'shunfa-tire', '模擬資料：週一、四送貨', first_day) returning id into s_tire;
  insert into public.suppliers (name, phone, line_id, note, created_at) values ('竹北零件批發（模擬）', '03-555-0303', 'zb-parts', '模擬資料：下午 3 點前叫，隔天到', first_day) returning id into s_parts;
  insert into public.suppliers (name, phone, line_id, note, created_at) values ('永光電池（模擬）', '03-555-0404', null, '模擬資料：週三送貨，只接電話', first_day) returning id into s_batt;

  insert into public.parts (name, spec, category, unit, safety_stock, price, supplier_id, note, created_at) values
    ('機油', '全合成 10W-40 1L',   '機油',   '瓶', 12,  450, s_oil,   '模擬資料', first_day),
    ('機油', '半合成 10W-30 0.8L', '機油',   '瓶', 15,  300, s_oil,   '模擬資料', first_day),
    ('機油', '礦物油 10W-30 0.8L', '機油',   '瓶', 10,  220, s_oil,   '模擬資料', first_day),
    ('齒輪油', '80W-90 120ml',     '齒輪油', '瓶', 15,  150, s_oil,   '模擬資料', first_day),
    ('煞車油', 'DOT4 500ml',       '煞車',   '瓶',  4,  300, s_oil,   '模擬資料', first_day),
    ('空濾', '勁戰六代',           '濾網',   '個',  4,  300, s_parts, '模擬資料', first_day),
    ('空濾', 'JET SL',             '濾網',   '個',  3,  300, s_parts, '模擬資料', first_day),
    ('空濾', 'DRG',                '濾網',   '個',  3,  350, s_parts, '模擬資料', first_day),
    ('空濾', 'Many 110',           '濾網',   '個',  3,  250, s_parts, '模擬資料', first_day),
    ('空濾', 'BWS',                '濾網',   '個',  2,  300, s_parts, '模擬資料', first_day),
    ('火星塞', 'CR7HSA',           '點火',   '顆',  6,  150, s_parts, '模擬資料', first_day),
    ('火星塞', 'CR8E',             '點火',   '顆',  6,  250, s_parts, '模擬資料', first_day),
    ('煞車皮', '前碟 通用',        '煞車',   '組',  5,  500, s_parts, '模擬資料', first_day),
    ('煞車皮', '後鼓 通用',        '煞車',   '組',  4,  400, s_parts, '模擬資料', first_day),
    ('皮帶', '勁戰六代',           '傳動',   '條',  2,  900, s_parts, '模擬資料', first_day),
    ('皮帶', 'JET SL',             '傳動',   '條',  2,  900, s_parts, '模擬資料', first_day),
    ('皮帶', 'Many 110',           '傳動',   '條',  2,  700, s_parts, '模擬資料', first_day),
    ('普利珠', '13g',              '傳動',   '組',  3,  400, s_parts, '模擬資料', first_day),
    ('普利珠', '14g',              '傳動',   '組',  3,  400, s_parts, '模擬資料', first_day),
    ('燈泡', 'H4 大燈',            '電系',   '顆',  4,  250, s_parts, '模擬資料', first_day),
    ('燈泡', 'T10 方向燈',         '電系',   '顆', 10,   50, s_parts, '模擬資料', first_day),
    ('輪胎', '110/70-12',          '輪胎',   '條',  4, 1600, s_tire,  '模擬資料', first_day),
    ('輪胎', '120/70-12',          '輪胎',   '條',  4, 1700, s_tire,  '模擬資料', first_day),
    ('輪胎', '90/90-10',           '輪胎',   '條',  3, 1200, s_tire,  '模擬資料', first_day),
    ('輪胎', '100/90-10',          '輪胎',   '條',  3, 1300, s_tire,  '模擬資料', first_day),
    ('內胎', '10 吋',              '輪胎',   '條',  4,  250, s_tire,  '模擬資料', first_day),
    ('電瓶', '7 號（YTX7A）',      '電系',   '顆',  3, 1300, s_batt,  '模擬資料', first_day),
    ('電瓶', '5 號（YTX5L）',      '電系',   '顆',  2, 1100, s_batt,  '模擬資料', first_day),
    ('電瓶', '9 號（YTX9）',       '電系',   '顆',  1, 1600, s_batt,  '模擬資料', first_day),
    ('雨刷水箱精', '1L',           '其他',   '瓶',  0,  120, null,    '模擬資料：很少用', first_day);

  -- 進價：機油利潤比較好，輪胎、電瓶利潤比較薄
  insert into public.part_costs (part_id, cost, updated_at)
  select id, round(price * case category
           when '機油' then 0.50 when '齒輪油' then 0.45 when '輪胎' then 0.72
           when '電系' then case when name = '電瓶' then 0.70 else 0.40 end
           else 0.55 end), first_day
  from public.parts;

  -- 期初盤點（第一天早上）
  insert into public.stock_moves (part_id, change, reason, note, created_at)
  select id, greatest(3, safety_stock * 3), '期初', '開始用系統時盤點',
         (first_day + time '08:30') at time zone 'Asia/Taipei'
  from public.parts;
  -- 很少用的東西一開始叫太多（庫存積壓）
  insert into public.stock_moves (part_id, change, reason, note, created_at)
  select id, 10, '進貨', '模擬資料：一次叫太多', (first_day + time '09:00') at time zone 'Asia/Taipei'
  from public.parts where (name, spec) in (('雨刷水箱精', '1L'), ('輪胎', '100/90-10'), ('電瓶', '9 號（YTX9）'), ('普利珠', '14g'));

  -- ===== 客戶和車輛：前 120 位一開始就有，其他兩年內陸續加入；1 成的人有兩台車 =====
  create temp table sim_pool (bike_id bigint, from_date date, mileage int, model text, oil int) on commit drop;
  for i in 1..500 loop
    insert into public.customers (name, phone, note, created_at)
    values (surnames[1 + floor(random() * 25)::int] || givens[1 + floor(random() * 20)::int],
            '0900-' || lpad((100 + floor(random() * 900))::text, 3, '0') || '-' || lpad(floor(random() * 1000)::text, 3, '0'),
            '模擬資料',
            first_day)
    returning id into cid;
    m := case when i <= 120 then first_day else first_day + floor(power(random(), 0.8) * 715)::int end;
    update public.customers set created_at = (m + time '10:00') at time zone 'Asia/Taipei' where id = cid;

    for k in 1..(case when random() < 0.1 then 2 else 1 end) loop
      loop
        new_plate := chr(65 + floor(random() * 26)::int) || chr(65 + floor(random() * 26)::int) || chr(65 + floor(random() * 26)::int)
                     || (1000 + floor(random() * 9000))::int;
        exit when not exists (select 1 from public.bikes where plate = new_plate);
      end loop;
      insert into public.bikes (customer_id, plate, model, year, mileage, created_at)
      values (cid, new_plate, models[1 + floor(random() * 12)::int],
              case when random() < 0.06 then null else 2012 + floor(random() * 14)::int end,
              5000 + floor(random() * 30000)::int, (m + time '10:00') at time zone 'Asia/Taipei')
      returning id into bid;
      insert into sim_pool
      select bid, m, mileage, model, 1 + floor(random() * 3)::int from public.bikes where id = bid;
    end loop;
  end loop;

  -- ===== 每天：叫貨到貨、工單、扣庫存 =====
  for d in select generate_series(first_day, today, interval '1 day')::date loop

    -- 一年後機油漲價（進價 +10%，售價 +30 元）
    if not oil_raised and d >= first_day + 400 then
      update public.part_costs c set cost = round(c.cost * 1.1), updated_at = (d + time '08:00') at time zone 'Asia/Taipei'
      from public.parts p where p.id = c.part_id and p.category = '機油';
      update public.parts set price = price + 30 where category = '機油';
      oil_raised := true;
    end if;

    -- 早上到貨：各家廠商在送貨日，把低於 1.5 倍安全庫存的補到 3 倍
    if extract(dow from d) <> 0 and d > first_day and not (d between cny1 - 1 and cny1 + 4 or d between cny2 - 1 and cny2 + 4) then
      for sp in select * from (values (s_oil, array[2, 5]), (s_tire, array[1, 4]), (s_parts, array[1, 2, 3, 4, 5, 6]), (s_batt, array[3])) v(sid, days) loop
        continue when not (extract(dow from d)::int = any(sp.days));
        select count(*) into cnt from public.parts
        where supplier_id = sp.sid and safety_stock > 0 and stock < safety_stock * 1.5;
        continue when cnt = 0;
        insert into public.purchase_orders (supplier_id, status, note, created_at, received_at)
        values (sp.sid, '已到貨', '模擬資料',
                ((d - 1) + time '17:30') at time zone 'Asia/Taipei', (d + time '09:30') at time zone 'Asia/Taipei')
        returning id into v_oid;
        insert into public.purchase_order_items (order_id, part_id, qty)
        select v_oid, id, safety_stock * 3 - stock from public.parts
        where supplier_id = sp.sid and safety_stock > 0 and stock < safety_stock * 1.5;
        insert into public.stock_moves (part_id, change, reason, order_id, note, created_at)
        select part_id, qty, '進貨', v_oid, '叫貨單 #' || v_oid || ' 到貨', (d + time '09:30') at time zone 'Asia/Taipei'
        from public.purchase_order_items where order_id = v_oid;
      end loop;
    end if;

    -- 今天有幾張單
    growth := case when d >= first_day + 365 then 1.12 else 1 end;
    busy := case
              when d between cny1 - 1 and cny1 + 4 or d between cny2 - 1 and cny2 + 4 then 0   -- 春節休息
              when d between cny1 - 10 and cny1 - 2 or d between cny2 - 10 and cny2 - 2 then 1.6 -- 過年前
              when extract(month from d) in (7, 8) then 1.2
              when extract(month from d) in (1, 12) then 0.9
              else 1
            end;
    n := round(growth * busy * case extract(dow from d)
           when 0 then floor(random() * 2)
           when 6 then 11 + floor(random() * 6)
           when 5 then 8 + floor(random() * 5)
           else 6 + floor(random() * 5)
         end)::int;
    last_hour := case when d = today then greatest(9, least(19, now_hour - 1)) else 19 end;
    if d = today and n < 6 then n := 6; end if;

    select count(*) into cnt from sim_pool where from_date <= d;
    continue when cnt = 0;

    for i in 1..n loop
      -- 常客來得比較勤
      select * into b from sim_pool where from_date <= d
      order by bike_id offset floor(power(random(), 1.3) * cnt)::int limit 1;

      its := '{}';
      for k in 1..10 loop
        continue when b.model = 'Gogoro VIVA' and item_names[k] in ('機油', '火星塞', '空濾', '普利珠');
        if random() < item_odds[k] then its := its || item_names[k]; end if;
      end loop;
      if cardinality(its) = 0 then
        its := case when b.model = 'Gogoro VIVA' then array['齒輪油'] else array['機油'] end;
      end if;
      -- 偶爾換燈泡
      if random() < 0.04 then its := its || '燈泡'::text; end if;

      km := greatest(300, coalesce(b.mileage, 12000) - (today + 1 - d) * 10 - 100);
      opened := d + make_interval(hours => 9 + floor(random() * (last_hour - 8))::int, mins => floor(random() * 60)::int);
      hrs := 0.5 + random() * 3.5;
      st := '已完成';
      done_at := (opened + make_interval(secs => hrs * 3600)) at time zone 'Asia/Taipei';
      if d = today and (i > n / 2 or done_at > now()) then
        st := case when i > n - 2 then '待修' else '維修中' end;
        done_at := null;
      end if;
      used_at := (opened + interval '20 minutes') at time zone 'Asia/Taipei';

      insert into public.service_records (bike_id, date, mileage, items, parts, total, status, next_service_km, created_at, completed_at)
      values (b.bike_id, d, km, array_to_string(its, '、'), '', 0, st,
              case when '機油' = any(its) then km + 1000 end,
              opened at time zone 'Asia/Taipei', done_at)
      returning id into rid;

      -- 每個項目用掉哪個零件（跟真的開單一樣：同一台車用同一種機油、空濾皮帶看車型）
      v_total := 0; labels := '{}'; its2 := '{}';
      foreach st in array its loop
        pid := null; q := 1; spec_want := null;
        case st
          when '機油' then
            select id into pid from public.parts where category = '機油' order by id offset b.oil - 1 limit 1;
          when '齒輪油' then
            select id into pid from public.parts where name = '齒輪油';
          when '煞車油' then
            select id into pid from public.parts where name = '煞車油';
          when '空濾' then spec_want := b.model;
            select id into pid from public.parts where name = '空濾' and spec = b.model;
          when '皮帶' then spec_want := b.model;
            select id into pid from public.parts where name = '皮帶' and spec = b.model;
          when '火星塞' then
            select id into pid from public.parts where name = '火星塞'
            order by id offset (b.bike_id % 2) limit 1;
          when '煞車皮' then
            select id into pid from public.parts where name = '煞車皮' order by random() limit 1;
          when '普利珠' then
            select id into pid from public.parts where name = '普利珠'
            order by case when spec = '13g' then 0 else 1 end, random() limit 1;
            q := 1;
          when '輪胎' then
            extra_name := case when b.model in ('Many 110', '迪爵 125', '新名流') then
                                 case when random() < 0.85 then '90/90-10' else '100/90-10' end
                               else case when random() < 0.6 then '110/70-12' else '120/70-12' end end;
            select id into pid from public.parts where name = '輪胎' and spec = extra_name;
          when '電瓶' then
            extra_name := case when b.model in ('Many 110', '迪爵 125') then '5 號（YTX5L）'
                               when random() < 0.05 then '9 號（YTX9）' else '7 號（YTX7A）' end;
            select id into pid from public.parts where name = '電瓶' and spec = extra_name;
          when '燈泡' then
            select id into pid from public.parts where name = '燈泡' order by random() limit 1;
            q := case when random() < 0.5 then 2 else 1 end;
          else null;
        end case;

        if pid is null and spec_want is not null and random() < 0.75 then
          continue;   -- 這台車型店裡沒備料，這次就沒換
        end if;
        its2 := its2 || st;
        if pid is null and spec_want is not null then
          -- 庫存沒有這台車型的空濾／皮帶：臨時叫貨
          select price into k from public.parts where name = st limit 1;
          insert into public.record_extras (record_id, kind, name, qty, sale_price, unit_cost, created_at)
          values (rid, '臨時零件', st || '（' || b.model || '）', 1, k + 50, round((k + 50) * 0.6), used_at);
          v_total := v_total + k + 50;
          labels := labels || (st || '（' || b.model || '）×1（臨時零件）');
        elsif pid is not null then
          -- 客人偶爾自己帶機油
          if st = '機油' and random() < 0.04 then
            insert into public.record_extras (record_id, kind, name, qty, sale_price, unit_cost, created_at)
            values (rid, '客人自備', '機油', 1, 0, null, used_at);
            labels := labels || '機油×1（客人自備）'::text;
            continue;
          end if;
          select * into pr from public.parts where id = pid;
          -- 庫存不夠：先臨時補貨（直接按「＋進貨」）
          if pr.stock < q then
            insert into public.stock_moves (part_id, change, reason, note, created_at)
            values (pid, pr.safety_stock * 2 + q, '進貨', '模擬資料：臨時補貨', used_at - interval '10 minutes');
          end if;
          insert into public.stock_moves (part_id, change, reason, record_id, created_at)
          values (pid, -q, '工單使用', rid, used_at);
          v_total := v_total + pr.price * q;
          labels := labels || (pr.name || ' ' || pr.spec || '×' || q);
        end if;
      end loop;

      its := case when cardinality(its2) > 0 then its2 else array['全車檢查'] end;
      -- 車禍維修（約 3%）：代工烤漆＋臨時零件
      if random() < 0.03 then
        its := its || '車禍維修'::text;
        extra_sale := (15 + floor(random() * 20)::int) * 100;
        insert into public.record_extras (record_id, kind, name, qty, sale_price, unit_cost, created_at)
        values (rid, '代工', '烤漆', 1, extra_sale, round(extra_sale * (0.55 + random() * 0.2)), used_at);
        extra_name := (array['右後照鏡', '左後照鏡', '前土除', '方向燈殼', '腳踏板'])[1 + floor(random() * 5)::int];
        extra_cost := (3 + floor(random() * 8)::int) * 50;
        insert into public.record_extras (record_id, kind, name, qty, sale_price, unit_cost, created_at)
        values (rid, '臨時零件', extra_name, 1, round(extra_cost * 1.6 / 10) * 10,
                case when random() < 0.85 then extra_cost end, used_at);   -- 少數忘了填成本
        v_total := v_total + extra_sale + round(extra_cost * 1.6 / 10) * 10;
        labels := labels || '烤漆×1（代工）'::text || (extra_name || '×1（臨時零件）');
      end if;

      labor := case when '輪胎' = any(its) then 200 else 0 end + (floor(random() * 5) * 50)::int + 50;
      update public.service_records
      set total = v_total + labor, parts = array_to_string(labels, '、'), items = array_to_string(its, '、')
      where id = rid;
    end loop;

    -- 偶爾盤點對不上
    if extract(day from d) = 28 then
      insert into public.stock_moves (part_id, change, reason, note, created_at)
      select id, -1, '盤點調整', '模擬資料：月底盤點少了', (d + time '19:30') at time zone 'Asia/Taipei'
      from public.parts where stock > 3 order by random() limit 1;
    end if;
  end loop;

  -- 今天有一張還沒到的叫貨單（輪胎）
  insert into public.purchase_orders (supplier_id, status, note, created_at)
  values (s_tire, '已叫貨', '模擬資料', now() - interval '3 hours')
  returning id into v_oid;
  insert into public.purchase_order_items (order_id, part_id, qty)
  select v_oid, id, 4 from public.parts where name = '輪胎' and spec in ('110/70-12', '120/70-12');

  -- 最近一週有幾樣用得兇，低於安全庫存（叫貨頁、看板提醒）
  insert into public.stock_moves (part_id, change, reason, note, created_at)
  select id, -(stock - safety_stock + 1), '盤點調整', '模擬資料：盤點發現少了', now() - interval '2 hours'
  from public.parts
  where stock > safety_stock
    and (name, spec) in (('空濾', 'DRG'), ('火星塞', 'CR8E'), ('電瓶', '5 號（YTX5L）'), ('煞車皮', '後鼓 通用'));

  -- ===== 預約 =====
  -- 過去：大多到店，一些取消，少數沒來；最近 3 個月開始有線上預約
  for d in select generate_series(first_day, today + 10, interval '1 day')::date loop
    continue when extract(dow from d) = 0 or d between cny1 - 1 and cny1 + 4 or d between cny2 - 1 and cny2 + 4;
    continue when d < today and random() >= 0.75;
    for i in 1..(case when d >= today then 1 + floor(random() * 3)::int else 1 end) loop
      select sp2.bike_id, bk.plate, c.name, c.phone into b
      from sim_pool sp2 join public.bikes bk on bk.id = sp2.bike_id join public.customers c on c.id = bk.customer_id
      where sp2.from_date <= least(d, today) order by random() limit 1;
      r := random();
      insert into public.appointments (date, time, plate, name, phone, items, status, source, created_at, seen_at)
      values (d,
              make_time((array[10, 11, 14, 15, 16, 17])[1 + floor(random() * 6)::int], 0, 0),
              b.plate, b.name, b.phone,
              (array['機油、齒輪油', '定期保養', '換輪胎', '煞車有異音', '電瓶沒電', '大保養'])[1 + floor(random() * 6)::int],
              case when d >= today then '預約中'
                   when r < 0.80 then '已到店' when r < 0.91 then '取消' else '沒來' end,
              case when d >= today - 90 and random() < 0.45 then '線上'
                   when d >= today and random() < 0.15 then '小助理' else '店內' end,
              ((d - 2) + time '12:00') at time zone 'Asia/Taipei',
              ((d - 2) + time '12:30') at time zone 'Asia/Taipei');
    end loop;
  end loop;
  -- 還沒建檔的新客人
  insert into public.appointments (date, time, plate, name, phone, items, status, source, created_at, seen_at)
  values (today + 2, '14:00', 'NEW' || (1000 + floor(random() * 9000))::int, '新客人', '0900-111-222', '大保養', '預約中', '店內', now(), now());
  -- 過期沒處理（前幾天的還是「預約中」）
  update public.appointments set status = '預約中'
  where id in (select id from public.appointments where date between today - 5 and today - 1 and status = '已到店' limit 3);
  -- 線上預約新消息：2 筆新預約還沒看、1 筆客人取消
  update public.appointments set seen_at = null, source = '線上', created_at = now() - interval '40 minutes'
  where id in (select id from public.appointments where date > today and status = '預約中' order by date limit 2);
  update public.appointments set seen_at = null, source = '線上', status = '取消'
  where id = (select id from public.appointments where date > today + 2 and status = '預約中' and seen_at is not null order by date limit 1);
  -- 有一位客人最近沒來 3 次（線上預約會被擋）
  select bk.plate, c.name, c.phone into b from public.bikes bk join public.customers c on c.id = bk.customer_id order by bk.id limit 1 offset 7;
  insert into public.appointments (date, time, plate, name, phone, items, status, source, created_at, seen_at)
  select today - x, '10:00', b.plate, b.name, b.phone, '機油', '沒來', '線上', now() - make_interval(days => x + 2), now()
  from unnest(array[20, 50, 90]) x;

  -- 線上預約：下週六公休、後天 14:00 不開放
  insert into public.booking_blocks (date, slot_time, reason)
  values (today + (13 - extract(dow from today)::int) % 7 + 7, null, '公休（模擬）'),
         (today + 2, '14:00', null);
  if not exists (select 1 from public.booking_slots) then
    insert into public.booking_slots (weekday, slot_time, capacity)
    select w, t::time, 2 from generate_series(1, 6) w, unnest(array['10:00', '11:00', '14:00', '15:00', '16:00', '17:00']) t;
  end if;
  update public.booking_settings set
    shop_phone = coalesce(shop_phone, '03-555-1234'),
    shop_address = coalesce(shop_address, '新竹縣竹北市（模擬地址）'),
    shop_hours = coalesce(shop_hours, '週一到週六 9:00–19:00，週日公休')
  where id = 1;

  -- 綁定碼（測客人網站用）
  insert into public.bind_codes (code, customer_id) select 'TEST2345', id from public.customers order by id limit 1;

  -- ===== 老闆專區：每月支出、廠商付款 =====
  for m in select generate_series(date_trunc('month', first_day)::date, date_trunc('month', today)::date, interval '1 month')::date loop
    insert into public.owner_expenses (date, category, item, amount, created_at) values
      (m + 4, '房租', '店面租金', 25000, (m + 4)::timestamptz),
      (m + 14, '水電', '台電、自來水', 2500 + floor(random() * 2000)::int
          + case when extract(month from m) in (7, 8) then 1500 else 0 end, (m + 14)::timestamptz),
      (m + 9, '薪資', '學徒薪水', case when m >= first_day + 365 then 33000 else 31000 end, (m + 9)::timestamptz),
      (m + 19, '雜支', '手套、清潔劑、抹布', 600 + floor(random() * 1200)::int, (m + 19)::timestamptz);
    if random() < 0.15 then
      insert into public.owner_expenses (date, category, item, amount, created_at)
      values (m + 11, '工具設備', (array['氣動扳手', '輪胎拆裝機保養', '千斤頂', '空壓機維修'])[1 + floor(random() * 4)::int],
              3000 + floor(random() * 12000)::int, (m + 11)::timestamptz);
    end if;
  end loop;
  -- 這個月還沒過完的，刪掉日期還沒到的支出
  delete from public.owner_expenses where date > today;

  -- 廠商付款：上上個月以前都付了，上個月和這個月還沒
  insert into public.owner_supplier_payments (supplier_id, month, amount, paid_at)
  select s.id, mm, coalesce((
      select round(sum(sm.change * mc.unit_cost)) from public.stock_moves sm
      join public.parts p on p.id = sm.part_id
      left join public.purchase_orders o on o.id = sm.order_id
      join public.move_costs mc on mc.move_id = sm.id
      where sm.reason = '進貨' and coalesce(o.supplier_id, p.supplier_id) = s.id
        and (sm.created_at at time zone 'Asia/Taipei') >= mm
        and (sm.created_at at time zone 'Asia/Taipei') < mm + interval '1 month'), 0),
    (mm + interval '1 month 5 days')::timestamptz
  from public.suppliers s,
       generate_series(date_trunc('month', first_day)::date,
                       (date_trunc('month', today) - interval '2 months')::date, interval '1 month') mm;

  -- 便條
  insert into public.notes (content, done, author, created_at) values
    ('下午三點有輪胎送來，記得簽收', false, '模擬資料', now() - interval '3 hours'),
    ('DRG 空濾剩不多，順便叫', false, '模擬資料', now() - interval '1 day'),
    ('機油回收桶滿了，聯絡回收商', true, '模擬資料', now() - interval '2 days');

  alter table public.customers       enable trigger log_changes;
  alter table public.bikes           enable trigger log_changes;
  alter table public.service_records enable trigger log_changes;
  alter table public.appointments    enable trigger log_changes;
  alter table public.parts           enable trigger log_changes;
  alter table public.suppliers       enable trigger log_changes;

  -- ===== 3. 做幾個修改、刪除，讓「操作紀錄」「垃圾桶」有東西（這時候會記紀錄） =====
  -- 改了金額
  update public.service_records set total = total - 100
  where id in (select id from public.service_records where status = '已完成' order by id desc limit 2 offset 5);
  -- 改了客人電話
  update public.customers set phone = '0900-555-666' where id = (select id from public.customers order by id limit 1 offset 3);
  -- 刪了一張工單（用掉的零件會加回庫存，垃圾桶救回時會再扣）
  delete from public.service_records
  where id = (select r.id from public.service_records r
              where r.status = '已完成' and exists (select 1 from public.stock_moves m where m.record_id = r.id)
              order by r.id desc limit 1 offset 10);
  -- 刪了一筆預約
  delete from public.appointments where id = (select id from public.appointments where status = '取消' and date < current_date order by date desc limit 1);
end $$;


-- ---------------------------------------------------------------------
-- 4. 看看結果
-- ---------------------------------------------------------------------
select '客戶' as 資料, count(*)::text as 數量 from public.customers
union all select '車輛', count(*)::text from public.bikes
union all select '工單', count(*)::text from public.service_records
union all select '今天的工單', count(*)::text || ' 張（' || string_agg(distinct status, '、') || '）' from public.service_records where date = (now() at time zone 'Asia/Taipei')::date
union all select '臨時零件／代工', count(*)::text from public.record_extras
union all select '預約', count(*)::text || '（線上 ' || count(*) filter (where source = '線上') || '、沒來 ' || count(*) filter (where status = '沒來') || '）' from public.appointments
union all select '零件', count(*)::text || ' 種（要叫貨 ' || count(*) filter (where stock <= safety_stock and safety_stock > 0) || ' 種）' from public.parts
union all select '叫貨單', count(*)::text from public.purchase_orders
union all select '庫存數量對得上', case when exists (select 1 from public.parts p where p.stock <> (select coalesce(sum(change), 0) from public.stock_moves m where m.part_id = p.id)) then '❌ 對不上' else '✅ 都對' end
union all select '兩年營收', to_char(sum(total), 'FM999,999,999') from public.service_records where status = '已完成'
union all select '其他支出筆數', count(*)::text from public.owner_expenses
union all select '操作紀錄', count(*)::text from public.activity_log;
