-- =====================================================================
-- 老闆版：模擬一整年的資料（測試用）
-- 日期從一年前一路到「今天」，今天也會有待修、維修中的工單，明天以後有預約
-- 內容：客戶 350 位（陸續加入）、約 3,000 張工單、約 280 筆預約、幾張便條
-- 灌資料時暫時關掉操作紀錄，避免垃圾桶和紀錄被幾千筆「新增」塞滿
--
-- ⚠ 交給老闆前，一定要執行「老闆版_清除模擬資料.sql」清乾淨
-- =====================================================================

alter table public.customers       disable trigger log_changes;
alter table public.bikes           disable trigger log_changes;
alter table public.service_records disable trigger log_changes;
alter table public.appointments    disable trigger log_changes;

do $$
declare
  surnames text[] := array['陳','林','黃','張','李','王','吳','劉','蔡','楊','許','鄭','謝','郭','洪','曾','邱','廖','賴','周'];
  givens   text[] := array['志明','雅婷','家豪','怡君','冠宇','淑芬','俊傑','美玲','建宏','佩珊','宗翰','欣怡','承恩','柏翰','思妤','子晴','宇軒','品妍'];
  models   text[] := array['勁戰六代','JET SL','DRG','MMBCU','Many 110','Gogoro VIVA','BWS','KRV','FORCE 2.0','迪爵 125','JETS','新名流'];
  item_names  text[] := array['機油','齒輪油','空濾','火星塞','煞車皮','煞車油','輪胎','皮帶','普利珠','電瓶'];
  item_prices int[]  := array[ 350,   150,    300,   250,     500,    300,    1600,  900,   400,    1300];
  item_odds   numeric[] := array[0.85, 0.55,  0.25,  0.15,    0.12,   0.06,   0.08,  0.05,  0.05,   0.05];

  today     date := (now() at time zone 'Asia/Taipei')::date;
  now_hour  int  := extract(hour from now() at time zone 'Asia/Taipei')::int;
  first_day date := ((now() at time zone 'Asia/Taipei')::date) - 364;

  d date; n int; i int; k int; cnt int; last_hour int;
  cid bigint; bid bigint; new_plate text;
  b record;
  its text[]; total int; km int; opened timestamp; hrs numeric; r numeric; busy numeric;
  st text; done_at timestamptz;
begin
  perform setseed(0.3141);
  create temp table sim_pool (bike_id bigint, from_date date, mileage int) on commit drop;

  -- 1. 客戶與車輛：前 100 位是一開始就有的老客人，其他 250 位在這一年陸續加入
  for i in 1..350 loop
    insert into public.customers (name, phone, note)
    values (surnames[1 + floor(random() * 20)::int] || givens[1 + floor(random() * 18)::int],
            '0900-' || lpad((100 + floor(random() * 900))::text, 3, '0') || '-' || lpad(floor(random() * 1000)::text, 3, '0'),
            '模擬資料')
    returning id into cid;

    loop
      new_plate := chr(65 + floor(random() * 26)::int) || chr(65 + floor(random() * 26)::int) || chr(65 + floor(random() * 26)::int)
                   || (1000 + floor(random() * 9000))::int;
      exit when not exists (select 1 from public.bikes where plate = new_plate);
    end loop;

    insert into public.bikes (customer_id, plate, model, year, mileage)
    values (cid, new_plate, models[1 + floor(random() * 12)::int],
            case when random() < 0.08 then null else 2010 + floor(random() * 16)::int end,
            8000 + floor(random() * 30000)::int)
    returning id into bid;

    insert into sim_pool
    select bid, case when i <= 100 then first_day else first_day + floor(random() * 350)::int end, mileage
    from public.bikes where id = bid;
  end loop;

  -- 2. 每天的工單
  for d in select generate_series(first_day, today, interval '1 day')::date loop
    busy := case
              when d between '2026-02-16' and '2026-02-20' then 0      -- 春節休息
              when d between '2026-02-07' and '2026-02-15' then 1.6    -- 過年前
              when extract(month from d) in (7, 8) then 1.2
              when extract(month from d) in (1, 12) then 0.9
              else 1
            end;
    n := round(busy * case extract(dow from d)
           when 0 then floor(random() * 3)
           when 6 then 11 + floor(random() * 6)
           when 5 then 8 + floor(random() * 5)
           else 6 + floor(random() * 5)
         end)::int;

    -- 今天：只產生「現在以前」進來的單
    last_hour := case when d = today then greatest(9, least(19, now_hour - 1)) else 19 end;
    if d = today and n < 6 then n := 6; end if;

    select count(*) into cnt from sim_pool where from_date <= d;
    continue when cnt = 0;

    for i in 1..n loop
      select p.bike_id, p.mileage into b
      from sim_pool p where p.from_date <= d
      order by p.bike_id offset floor(power(random(), 1.5) * cnt)::int limit 1;

      its := '{}';
      total := 0;
      for k in 1..10 loop
        if random() < item_odds[k] then
          its := its || item_names[k];
          total := total + item_prices[k];
        end if;
      end loop;
      if cardinality(its) = 0 then
        its := array['機油'];
        total := 350;
      end if;
      total := total + (floor(random() * 5) * 50)::int;

      km := greatest(300, coalesce(b.mileage, 12000) - (today + 1 - d) * 12 - 100);
      opened := d + make_interval(hours => 9 + floor(random() * (last_hour - 8))::int, mins => floor(random() * 60)::int);
      hrs := 0.5 + random() * 3.5;

      -- 今天的單：前面的已完成，後面的還在修或等著修
      st := '已完成';
      done_at := (opened + make_interval(secs => hrs * 3600)) at time zone 'Asia/Taipei';
      if d = today and (i > n / 2 or done_at > now()) then
        st := case when i > n - 2 then '待修' else '維修中' end;
        done_at := null;
      end if;

      insert into public.service_records (bike_id, date, mileage, items, parts, total, status, next_service_km, created_at, completed_at)
      values (b.bike_id, d, km, array_to_string(its, '、'),
              case when '機油' = any(its) then '機油 0.8L' else '' end,
              total, st,
              case when '機油' = any(its) then km + 1000 end,
              opened at time zone 'Asia/Taipei',
              done_at);
    end loop;
  end loop;

  -- 3. 預約：過去的有到店／取消／沒來；今天到下週是「預約中」
  for d in select generate_series(first_day, today + 7, interval '1 day')::date loop
    continue when extract(dow from d) = 0 or d between '2026-02-16' and '2026-02-20';
    continue when d <= today and random() >= 0.8;
    for i in 1..(case when d > today then 1 + floor(random() * 2)::int else 1 end) loop
      r := random();
      if d > today and random() < 0.25 then
        -- 還沒建檔的新客人
        insert into public.appointments (date, time, plate, name, phone, items, status, source, created_at)
        values (d, make_time(10 + floor(random() * 8)::int, (floor(random() * 2) * 30)::int, 0),
                'NEW' || (1000 + floor(random() * 9000))::int, '新客人', '0900-111-' || lpad(floor(random() * 1000)::text, 3, '0'),
                '大保養', '預約中', '店內', now());
      else
        select bk.plate, c.name, c.phone into b
        from sim_pool p join public.bikes bk on bk.id = p.bike_id left join public.customers c on c.id = bk.customer_id
        where p.from_date <= least(d, today)
        order by random() limit 1;
        insert into public.appointments (date, time, plate, name, phone, items, status, source, created_at)
        values (d, make_time(10 + floor(random() * 8)::int, (floor(random() * 2) * 30)::int, 0),
                b.plate, coalesce(b.name, ''), coalesce(b.phone, ''), '機油、齒輪油',
                case when d >= today then '預約中' when r < 0.75 then '已到店' when r < 0.88 then '取消' else '預約中' end,
                '店內', (d - 2)::timestamp at time zone 'Asia/Taipei');
      end if;
    end loop;
  end loop;

  -- 4. 便條
  insert into public.notes (content, done, author, created_at) values
    ('下午三點有零件送來，記得簽收', false, '模擬資料', now() - interval '3 hours'),
    ('前煞車皮剩 2 組，要叫貨', false, '模擬資料', now() - interval '1 day'),
    ('機油回收桶滿了，聯絡回收商', true, '模擬資料', now() - interval '2 days');
end $$;

alter table public.customers       enable trigger log_changes;
alter table public.bikes           enable trigger log_changes;
alter table public.service_records enable trigger log_changes;
alter table public.appointments    enable trigger log_changes;

-- 5. 看看加了多少
select '客戶' as 資料, count(*)::text as 數量 from public.customers
union all select '車輛', count(*)::text from public.bikes
union all select '工單', count(*)::text from public.service_records
union all select '今天的工單', count(*)::text || ' 張（' || string_agg(distinct status, '、') || '）' from public.service_records where date = (now() at time zone 'Asia/Taipei')::date
union all select '預約', count(*)::text from public.appointments
union all select '一年營收', to_char(sum(total), 'FM999,999,999') from public.service_records where status = '已完成'
union all select '操作紀錄（應該是 0）', count(*)::text from public.activity_log;
