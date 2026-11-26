-- =====================================================================
-- 老闆版：新車進貨與銷售（先跑過 1～6 再跑這個；可以重複執行）
--
--   1. 新車庫存：一台一筆（車架號不重複），在庫／已售／退回
--   2. 新車進價：只有老闆看得到（員工進車時可以順手填，但填完就看不到）
--   3. 賣出新車：一次完成「建客戶（或選舊客戶）→ 建車輛資料 → 新車改成已售」
--   4. 老闆專區：新車的營收、成本、毛利算進報表與「實際賺」，新車庫存價值另外列
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. 資料表
-- ---------------------------------------------------------------------
create table if not exists public.new_bikes (
  id          bigint generated always as identity primary key,
  brand       text,                                   -- 廠牌，例如：三陽
  model       text not null,                          -- 車型，例如：JET SL 125
  color       text,
  year        int check (year between 1950 and 2100), -- 年份
  frame_no    text unique,                            -- 車架號碼（同一台不能進兩次）
  engine_no   text,                                   -- 引擎號碼
  supplier_id bigint references public.suppliers(id) on delete set null,
  list_price  int check (list_price >= 0),            -- 建議售價
  status      text not null default '在庫' check (status in ('在庫', '已售', '退回')),
  received_at date not null default ((now() at time zone 'Asia/Taipei')::date),  -- 進貨日
  sold_at     date,                                   -- 賣出日（營收算在這天）
  sale_price  int check (sale_price >= 0),            -- 實際賣價
  customer_id bigint references public.customers(id) on delete set null,
  bike_id     bigint references public.bikes(id) on delete set null,  -- 賣出後建立的車輛資料
  note        text,
  created_at  timestamptz not null default now(),
  constraint new_bikes_sold_check check (status <> '已售' or (sold_at is not null and sale_price is not null))
);
create index if not exists new_bikes_status_idx on public.new_bikes (status);
create index if not exists new_bikes_sold_idx   on public.new_bikes (sold_at);

alter table public.new_bikes enable row level security;
drop policy if exists "staff only" on public.new_bikes;
create policy "staff only" on public.new_bikes for all to authenticated
  using ((select public.is_staff())) with check ((select public.is_staff()));
grant select, insert, update, delete on public.new_bikes to authenticated;

-- 進價：只有老闆看得到（沒有任何規則 = 網頁碰不到，只能透過下面的函式）
create table if not exists public.new_bike_costs (
  new_bike_id bigint primary key references public.new_bikes(id) on delete cascade,
  cost        numeric(12, 0) not null check (cost >= 0),
  updated_at  timestamptz not null default now()
);
alter table public.new_bike_costs enable row level security;
revoke all on public.new_bike_costs from anon, authenticated;

-- 操作紀錄（新增、修改、刪除新車都會記下來）
drop trigger if exists log_changes on public.new_bikes;
create trigger log_changes after insert or update or delete on public.new_bikes
  for each row execute function public.log_change();


-- ---------------------------------------------------------------------
-- 2. 員工進車時填進價：只能「第一次填」，之後要改只能到老闆專區
-- ---------------------------------------------------------------------
create or replace function public.set_new_bike_cost(p_id bigint, p_cost numeric)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_staff() then
    raise exception '沒有權限';
  end if;
  if p_cost is null then
    return;
  end if;
  if p_cost < 0 or p_cost > 10000000 then
    raise exception '進價不合理';
  end if;
  if not exists (select 1 from public.new_bikes where id = p_id) then
    raise exception '找不到這台新車';
  end if;
  insert into public.new_bike_costs (new_bike_id, cost) values (p_id, p_cost)
  on conflict (new_bike_id) do nothing;   -- 已經有進價就不蓋掉（改進價請到老闆專區）
end $$;
revoke execute on function public.set_new_bike_cost(bigint, numeric) from public, anon;
grant execute on function public.set_new_bike_cost(bigint, numeric) to authenticated;


-- ---------------------------------------------------------------------
-- 3. 賣出新車（全部成功或全部不做）
--    選舊客戶：給 p_customer_id；新客戶：給 p_name（和 p_phone）
-- ---------------------------------------------------------------------
create or replace function public.sell_new_bike(
  p_id bigint, p_plate text, p_price int,
  p_customer_id bigint default null, p_name text default null, p_phone text default null,
  p_date date default null)
returns bigint
language plpgsql
security invoker
set search_path = ''
as $$
declare
  nb   public.new_bikes%rowtype;
  cid  bigint := p_customer_id;
  v_plate text := upper(regexp_replace(coalesce(p_plate, ''), '[^A-Za-z0-9]', '', 'g'));
  bid  bigint;
begin
  if not public.is_staff() then
    raise exception '沒有權限';
  end if;
  select * into nb from public.new_bikes where id = p_id for update;
  if not found then
    raise exception '找不到這台新車';
  end if;
  if nb.status <> '在庫' then
    raise exception '這台車是「%」，不能再賣', nb.status;
  end if;
  if v_plate = '' then
    raise exception '請填車牌';
  end if;
  if p_price is null or p_price < 0 then
    raise exception '請填賣價';
  end if;
  if exists (select 1 from public.bikes where plate = v_plate) then
    raise exception '車牌 % 已經有資料了，請確認有沒有打錯', v_plate;
  end if;

  if cid is null then
    if coalesce(trim(p_name), '') = '' then
      raise exception '請選客戶，或填新客戶的名字';
    end if;
    insert into public.customers (name, phone)
    values (trim(p_name), nullif(trim(coalesce(p_phone, '')), ''))
    returning id into cid;
  elsif not exists (select 1 from public.customers where id = cid) then
    raise exception '找不到這位客戶';
  end if;

  insert into public.bikes (customer_id, plate, model, year, mileage)
  values (cid, v_plate, nb.model, nb.year, 0)
  returning id into bid;

  update public.new_bikes
  set status = '已售', sold_at = coalesce(p_date, public.tw_now()::date), sale_price = p_price,
      customer_id = cid, bike_id = bid
  where id = p_id;
  return bid;
end $$;
revoke execute on function public.sell_new_bike(bigint, text, int, bigint, text, text, date) from public, anon;
grant execute on function public.sell_new_bike(bigint, text, int, bigint, text, text, date) to authenticated;

-- 賣錯了：改回在庫（已經建立的客戶、車輛資料保留，需要的話自己刪）
create or replace function public.unsell_new_bike(p_id bigint)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if not public.is_staff() then
    raise exception '沒有權限';
  end if;
  update public.new_bikes
  set status = '在庫', sold_at = null, sale_price = null, customer_id = null, bike_id = null
  where id = p_id and status = '已售';
  if not found then
    raise exception '這台車不是已售狀態';
  end if;
end $$;
revoke execute on function public.unsell_new_bike(bigint) from public, anon;
grant execute on function public.unsell_new_bike(bigint) to authenticated;


-- ---------------------------------------------------------------------
-- 4. 老闆專區：新車清單（含進價、毛利、放了幾天）與改進價
-- ---------------------------------------------------------------------
create or replace function public.owner_new_bikes(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.owner_check(p_token);
  return coalesce((
    select jsonb_agg(x order by x.status, x.sold_at desc nulls last, x.received_at desc, x.id desc) from (
      select nb.id, nb.brand, nb.model, nb.color, nb.year, nb.frame_no, nb.status,
             nb.received_at, nb.sold_at, nb.list_price, nb.sale_price,
             c.cost, s.name as supplier, cu.name as customer, b.plate,
             (coalesce(nb.sold_at, public.tw_now()::date) - nb.received_at) as days
      from public.new_bikes nb
      left join public.new_bike_costs c on c.new_bike_id = nb.id
      left join public.suppliers s on s.id = nb.supplier_id
      left join public.customers cu on cu.id = nb.customer_id
      left join public.bikes b on b.id = nb.bike_id
      where nb.status <> '退回') x), '[]'::jsonb);
end $$;
revoke execute on function public.owner_new_bikes(text) from public, anon;
grant execute on function public.owner_new_bikes(text) to authenticated;

create or replace function public.owner_set_new_bike_cost(p_token text, p_id bigint, p_cost numeric)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.owner_check(p_token);
  if p_cost is null then
    delete from public.new_bike_costs where new_bike_id = p_id;
    return;
  end if;
  if p_cost < 0 then
    raise exception '進價不能是負的';
  end if;
  insert into public.new_bike_costs (new_bike_id, cost, updated_at) values (p_id, p_cost, now())
  on conflict (new_bike_id) do update set cost = excluded.cost, updated_at = now();
end $$;
revoke execute on function public.owner_set_new_bike_cost(text, bigint, numeric) from public, anon;
grant execute on function public.owner_set_new_bike_cost(text, bigint, numeric) to authenticated;


-- ---------------------------------------------------------------------
-- 5. 報表（取代第二批的版本）：每個月多了新車的營收、成本、台數
-- ---------------------------------------------------------------------
create or replace function public.owner_report(p_token text, p_month date default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  m0 date := date_trunc('month', coalesce(p_month, public.tw_now()::date))::date;
  m1 date := (m0 + interval '1 month')::date;
begin
  perform public.owner_check(p_token);
  return jsonb_build_object(
    'month', to_char(m0, 'YYYY-MM'),
    'trend', (
      select jsonb_agg(t order by t.month) from (
        select to_char(mm, 'YYYY-MM') as month,
               coalesce(sum(n.total), 0) as revenue,
               coalesce(sum(n.parts_cost), 0) as parts_cost,
               coalesce(sum(n.extra_cost), 0) as extra_cost,
               coalesce(sum(n.parts_sales + n.extra_sales), 0) as parts_sales,
               count(n.record_id) as orders,
               count(distinct (n.bike_id, n.done_date)) as visits,
               coalesce((select sum(e.amount) from public.owner_expenses e
                 where e.date >= mm and e.date < mm + interval '1 month'), 0) as expenses,
               coalesce((select sum(nb.sale_price) from public.new_bikes nb
                 where nb.status = '已售' and nb.sold_at >= mm and nb.sold_at < mm + interval '1 month'), 0) as bike_revenue,
               coalesce((select sum(c.cost) from public.new_bikes nb
                 join public.new_bike_costs c on c.new_bike_id = nb.id
                 where nb.status = '已售' and nb.sold_at >= mm and nb.sold_at < mm + interval '1 month'), 0) as bike_cost,
               (select count(*) from public.new_bikes nb
                 where nb.status = '已售' and nb.sold_at >= mm and nb.sold_at < mm + interval '1 month') as bikes_sold
        from generate_series(m0 - interval '23 months', m0, interval '1 month') mm
        left join public.owner_record_numbers(
          (m0 - interval '23 months')::date, (m1 - 1)) n
          on n.done_date >= mm and n.done_date < mm + interval '1 month'
        group by mm
      ) t),
    'parts', coalesce((
      select jsonb_agg(x order by x.profit desc nulls last) from (
        select p.id, p.name, p.spec, p.unit, p.price, c.cost,
               sum(-m.change)::int as qty,
               sum(-m.change * p.price) as sales,
               sum(-m.change * mc.unit_cost) as cost_total,
               sum(-m.change * (p.price - mc.unit_cost)) as profit,
               count(*) filter (where mc.move_id is null) as no_cost
        from public.stock_moves m
        join public.service_records r on r.id = m.record_id
        join public.parts p on p.id = m.part_id
        left join public.part_costs c on c.part_id = p.id
        left join public.move_costs mc on mc.move_id = m.id
        where m.reason = '工單使用' and r.status = '已完成'
          and (r.completed_at at time zone 'Asia/Taipei') >= m0
          and (r.completed_at at time zone 'Asia/Taipei') < m1
        group by p.id, p.name, p.spec, p.unit, p.price, c.cost
        having sum(-m.change) <> 0) x), '[]'::jsonb),
    'missing_cost', (
      select count(*) from public.owner_record_numbers(m0, (m1 - 1)) n where n.missing_cost > 0),
    -- 這個月還沒過完：跟「去年同一段日期」比才公平（例如 11/1～11/25）
    'ly_same', case when m0 = date_trunc('month', public.tw_now()::date)::date then (
      select jsonb_build_object(
        'to', (public.tw_now()::date - interval '1 year')::date,
        'revenue', coalesce(sum(n.total), 0),
        'cost', coalesce(sum(n.parts_cost + n.extra_cost), 0),
        'visits', count(distinct (n.bike_id, n.done_date)),
        'bike_revenue', (select coalesce(sum(nb.sale_price), 0) from public.new_bikes nb
          where nb.status = '已售' and nb.sold_at between (m0 - interval '1 year')::date
                and (public.tw_now()::date - interval '1 year')::date),
        'bike_cost', (select coalesce(sum(c.cost), 0) from public.new_bikes nb
          join public.new_bike_costs c on c.new_bike_id = nb.id
          where nb.status = '已售' and nb.sold_at between (m0 - interval '1 year')::date
                and (public.tw_now()::date - interval '1 year')::date))
      from public.owner_record_numbers((m0 - interval '1 year')::date,
                                       (public.tw_now()::date - interval '1 year')::date) n) end,
    'expenses', coalesce((
      select jsonb_agg(e order by e.date desc, e.id desc) from (
        select id, date, category, item, amount from public.owner_expenses
        where date >= m0 and date < m1) e), '[]'::jsonb),
    'stock_value', (
      select coalesce(sum(p.stock * c.cost), 0) from public.parts p
      join public.part_costs c on c.part_id = p.id where p.stock > 0),
    'bike_stock', (select count(*) from public.new_bikes where status = '在庫'),
    'bike_stock_value', (select coalesce(sum(c.cost), 0) from public.new_bikes nb
      join public.new_bike_costs c on c.new_bike_id = nb.id where nb.status = '在庫'),
    'bike_no_cost', (select count(*) from public.new_bikes nb
      where nb.status in ('在庫', '已售')
        and not exists (select 1 from public.new_bike_costs c where c.new_bike_id = nb.id)),
    'stock_no_cost', (
      select count(*) from public.parts p
      where p.active and p.stock > 0
        and not exists (select 1 from public.part_costs c where c.part_id = p.id))
  );
end $$;
revoke execute on function public.owner_report(text, date) from public, anon;
grant execute on function public.owner_report(text, date) to authenticated;


-- 檢查：最下面 3 個都是 true 就成功了
select
  exists (select 1 from information_schema.tables where table_schema = 'public' and table_name = 'new_bikes') as "新車表",
  exists (select 1 from pg_proc where proname = 'sell_new_bike') as "賣出新車",
  exists (select 1 from pg_proc where proname = 'owner_new_bikes') as "老闆新車清單";
