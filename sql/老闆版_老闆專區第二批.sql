-- =====================================================================
-- 老闆版：老闆專區第二批
-- 先跑過「老闆版_老闆專區與改進.sql」，再執行這個檔案。可以重複執行。
--
--   1. 每張工單的毛利：臨時零件、代工也能記成本（員工開單時填，只有老闆看得到）
--   2. 工錢估算：工單金額 − 零件售價
--   4. 跟去年同月比較
--   5. 大客戶排行
--   7. 客單價
--   8. 庫存積壓：放很久沒用的零件佔多少錢
--   9. 廠商對帳：每月跟每家廠商進了多少錢、付款了沒
--  10. 操作紀錄只有老闆看得到（員工的垃圾桶照常可以用）
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. 工單上的臨時零件、代工、客人自備（不在庫存裡的）
--    員工開單時寫進來（只能寫、不能讀），老闆專區才看得到
-- ---------------------------------------------------------------------
create table if not exists public.record_extras (
  id         bigint generated always as identity primary key,
  record_id  bigint not null references public.service_records(id) on delete cascade,
  kind       text not null,                    -- 臨時零件／代工／客人自備
  name       text not null,
  qty        int not null default 1 check (qty > 0),
  sale_price numeric(10, 2) not null default 0, -- 收客人的單價
  unit_cost  numeric(10, 2),                   -- 成本單價（空白 = 還沒填）
  created_at timestamptz not null default now()
);
create index if not exists record_extras_record_idx on public.record_extras (record_id);
alter table public.record_extras enable row level security;
revoke all on public.record_extras from anon, authenticated;

-- 員工開單時呼叫：把這張工單的臨時零件、代工記下來
create or replace function public.add_record_extras(p_record_id bigint, p_items jsonb)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  it jsonb;
  n int := 0;
begin
  if not public.is_staff() then
    raise exception '沒有權限';
  end if;
  if not exists (select 1 from public.service_records where id = p_record_id) then
    raise exception '找不到這張工單';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 30 then
    raise exception '資料格式不對';
  end if;
  for it in select * from jsonb_array_elements(p_items) loop
    insert into public.record_extras (record_id, kind, name, qty, sale_price, unit_cost)
    values (p_record_id,
            left(coalesce(nullif(trim(it->>'kind'), ''), '臨時零件'), 10),
            left(coalesce(nullif(trim(it->>'name'), ''), '未命名'), 60),
            greatest(1, least(999, coalesce((it->>'qty')::int, 1))),
            greatest(0, least(1000000, coalesce((it->>'sale_price')::numeric, 0))),
            case when nullif(it->>'unit_cost', '') is null then null
                 else greatest(0, least(1000000, (it->>'unit_cost')::numeric)) end);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public.add_record_extras(bigint, jsonb) from public, anon;
grant execute on function public.add_record_extras(bigint, jsonb) to authenticated;


-- ---------------------------------------------------------------------
-- 9. 進貨也記下當時的進價（廠商對帳用）
-- ---------------------------------------------------------------------
create or replace function public.record_move_cost()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  c numeric;
begin
  if new.reason in ('工單使用', '進貨') or new.change < 0 then
    select cost into c from public.part_costs where part_id = new.part_id;
    if c is not null then
      insert into public.move_costs (move_id, unit_cost) values (new.id, c)
      on conflict (move_id) do nothing;
    end if;
  end if;
  return new;
end $$;

-- 設定進價時，補到以前沒有進價的「用掉」和「進貨」紀錄
create or replace function public.owner_set_cost(p_token text, p_part_id bigint, p_cost numeric, p_backfill boolean default true)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  n int := 0;
begin
  perform public.owner_check(p_token);
  if p_cost is null then
    delete from public.part_costs where part_id = p_part_id;
    return 0;
  end if;
  if p_cost < 0 or p_cost > 1000000 then
    raise exception '進價不合理';
  end if;
  insert into public.part_costs (part_id, cost, updated_at) values (p_part_id, p_cost, now())
  on conflict (part_id) do update set cost = excluded.cost, updated_at = now();
  if p_backfill then
    insert into public.move_costs (move_id, unit_cost)
    select m.id, p_cost from public.stock_moves m
    where m.part_id = p_part_id and (m.change < 0 or m.reason in ('工單使用', '進貨'))
      and not exists (select 1 from public.move_costs mc where mc.move_id = m.id);
    get diagnostics n = row_count;
  end if;
  return n;
end $$;

-- 付款紀錄：哪家廠商、哪個月、付了沒
create table if not exists public.owner_supplier_payments (
  supplier_id bigint not null references public.suppliers(id) on delete cascade,
  month       date not null,
  amount      numeric(12, 0),
  paid_at     timestamptz not null default now(),
  primary key (supplier_id, month)
);
alter table public.owner_supplier_payments enable row level security;
revoke all on public.owner_supplier_payments from anon, authenticated;


-- ---------------------------------------------------------------------
-- 一張工單的金額拆解（給下面的報表共用）
--   零件售價 = 庫存零件 × 目前售價 ＋ 臨時零件／代工收的錢
--   成本     = 庫存零件 × 當時進價 ＋ 臨時零件／代工的成本
--   工錢     = 工單金額 − 零件售價
-- ---------------------------------------------------------------------
create or replace function public.owner_record_numbers(p_from date, p_to date)
returns table (record_id bigint, done_date date, bike_id bigint, total numeric,
               parts_sales numeric, parts_cost numeric, extra_sales numeric, extra_cost numeric,
               missing_cost int)
language sql
stable
security definer
set search_path = ''
as $$
  select r.id,
         (r.completed_at at time zone 'Asia/Taipei')::date,
         r.bike_id,
         coalesce(r.total, 0),
         coalesce(sm.sales, 0), coalesce(sm.cost, 0),
         coalesce(ex.sales, 0), coalesce(ex.cost, 0),
         coalesce(sm.missing, 0) + coalesce(ex.missing, 0)
  from public.service_records r
  left join lateral (
    select sum(-m.change * p.price) as sales,
           sum(-m.change * mc.unit_cost) as cost,
           count(*) filter (where mc.move_id is null)::int as missing
    from public.stock_moves m
    join public.parts p on p.id = m.part_id
    left join public.move_costs mc on mc.move_id = m.id
    where m.record_id = r.id and m.reason = '工單使用'
  ) sm on true
  left join lateral (
    select sum(e.qty * e.sale_price) as sales,
           sum(e.qty * e.unit_cost) as cost,
           count(*) filter (where e.unit_cost is null and e.kind <> '客人自備')::int as missing
    from public.record_extras e where e.record_id = r.id
  ) ex on true
  where r.status = '已完成'
    and (r.completed_at at time zone 'Asia/Taipei')::date between p_from and p_to
$$;
revoke execute on function public.owner_record_numbers(date, date) from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- 報表（取代舊版）：24 個月的趨勢（可以跟去年同月比）
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
                 where e.date >= mm and e.date < mm + interval '1 month'), 0) as expenses
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
    'expenses', coalesce((
      select jsonb_agg(e order by e.date desc, e.id desc) from (
        select id, date, category, item, amount from public.owner_expenses
        where date >= m0 and date < m1) e), '[]'::jsonb),
    'stock_value', (
      select coalesce(sum(p.stock * c.cost), 0) from public.parts p
      join public.part_costs c on c.part_id = p.id where p.stock > 0),
    'stock_no_cost', (
      select count(*) from public.parts p
      where p.active and p.stock > 0
        and not exists (select 1 from public.part_costs c where c.part_id = p.id))
  );
end $$;


-- ---------------------------------------------------------------------
-- 1、2. 每張工單的毛利和工錢
-- ---------------------------------------------------------------------
create or replace function public.owner_orders(p_token text, p_month date default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  m0 date := date_trunc('month', coalesce(p_month, public.tw_now()::date))::date;
begin
  perform public.owner_check(p_token);
  return coalesce((
    select jsonb_agg(x order by x.profit asc, x.done_date) from (
      select n.record_id as id, n.done_date, b.plate, b.model, c.name as customer, r.items, n.total,
             n.parts_sales + n.extra_sales as parts_sales,
             n.parts_cost + n.extra_cost as cost,
             n.total - n.parts_cost - n.extra_cost as profit,
             n.total - n.parts_sales - n.extra_sales as labor,
             n.missing_cost,
             (select jsonb_agg(jsonb_build_object('id', e.id, 'kind', e.kind, 'name', e.name, 'qty', e.qty,
                       'sale_price', e.sale_price, 'unit_cost', e.unit_cost) order by e.id)
              from public.record_extras e where e.record_id = n.record_id) as extras
      from public.owner_record_numbers(m0, (m0 + interval '1 month')::date - 1) n
      join public.service_records r on r.id = n.record_id
      join public.bikes b on b.id = n.bike_id
      left join public.customers c on c.id = b.customer_id) x), '[]'::jsonb);
end $$;

-- 補填臨時零件／代工的成本
create or replace function public.owner_set_extra_cost(p_token text, p_id bigint, p_cost numeric)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.owner_check(p_token);
  if p_cost is not null and (p_cost < 0 or p_cost > 1000000) then
    raise exception '成本不合理';
  end if;
  update public.record_extras set unit_cost = p_cost where id = p_id;
end $$;


-- ---------------------------------------------------------------------
-- 5、7. 大客戶排行（最近 12 個月）
-- ---------------------------------------------------------------------
create or replace function public.owner_customers(p_token text, p_months int default 12)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  d0 date := (public.tw_now()::date - make_interval(months => greatest(1, least(p_months, 36))))::date;
begin
  perform public.owner_check(p_token);
  return jsonb_build_object(
    'since', d0,
    'top', coalesce((
      select jsonb_agg(x order by x.spent desc) from (
        select c.id, c.name,
               (select string_agg(b2.plate, '、') from public.bikes b2 where b2.customer_id = c.id) as plates,
               count(distinct (r.bike_id, (r.completed_at at time zone 'Asia/Taipei')::date)) as visits,
               sum(r.total) as spent,
               max((r.completed_at at time zone 'Asia/Taipei')::date) as last_visit
        from public.service_records r
        join public.bikes b on b.id = r.bike_id
        join public.customers c on c.id = b.customer_id
        where r.status = '已完成' and (r.completed_at at time zone 'Asia/Taipei')::date >= d0
        group by c.id, c.name
        order by sum(r.total) desc
        limit 20) x), '[]'::jsonb),
    'total_customers', (
      select count(distinct b.customer_id) from public.service_records r
      join public.bikes b on b.id = r.bike_id
      where r.status = '已完成' and (r.completed_at at time zone 'Asia/Taipei')::date >= d0),
    'total_spent', (
      select coalesce(sum(r.total), 0) from public.service_records r
      where r.status = '已完成' and (r.completed_at at time zone 'Asia/Taipei')::date >= d0)
  );
end $$;


-- ---------------------------------------------------------------------
-- 8. 庫存積壓：每個有庫存的零件，最後一次被用掉是哪天
-- ---------------------------------------------------------------------
create or replace function public.owner_aging(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.owner_check(p_token);
  return coalesce((
    select jsonb_agg(x order by x.value desc nulls last) from (
      select p.id, p.name, p.spec, p.category, p.unit, p.stock, p.active, c.cost,
             p.stock * c.cost as value,
             (select max(m.created_at) from public.stock_moves m
              where m.part_id = p.id and m.reason = '工單使用' and m.change < 0) as last_used,
             (select min(m.created_at) from public.stock_moves m where m.part_id = p.id) as first_move
      from public.parts p
      left join public.part_costs c on c.part_id = p.id
      where p.stock > 0) x), '[]'::jsonb);
end $$;


-- ---------------------------------------------------------------------
-- 9. 廠商對帳：某個月每家廠商進了多少貨
--    叫貨單到貨的，算叫貨單的廠商；直接按「＋進貨」的，算零件設定的廠商
-- ---------------------------------------------------------------------
create or replace function public.owner_suppliers(p_token text, p_month date default null)
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
  return coalesce((
    select jsonb_agg(x order by x.amount desc nulls last) from (
      select s.id, s.name, s.phone,
             count(distinct coalesce(m.order_id::text, m.created_at::date::text)) as deliveries,
             sum(m.change * mc.unit_cost) as amount,
             count(*) filter (where mc.move_id is null) as no_cost,
             jsonb_agg(jsonb_build_object(
               'date', (m.created_at at time zone 'Asia/Taipei')::date,
               'part', p.name || coalesce(' ' || p.spec, ''), 'qty', m.change, 'unit', p.unit,
               'unit_cost', mc.unit_cost, 'order_id', m.order_id) order by m.created_at) as items,
             (select jsonb_build_object('amount', sp.amount, 'paid_at', sp.paid_at)
              from public.owner_supplier_payments sp where sp.supplier_id = s.id and sp.month = m0) as paid
      from public.stock_moves m
      join public.parts p on p.id = m.part_id
      left join public.purchase_orders o on o.id = m.order_id
      join public.suppliers s on s.id = coalesce(o.supplier_id, p.supplier_id)
      left join public.move_costs mc on mc.move_id = m.id
      where m.reason = '進貨'
        and (m.created_at at time zone 'Asia/Taipei') >= m0
        and (m.created_at at time zone 'Asia/Taipei') < m1
      group by s.id, s.name, s.phone) x), '[]'::jsonb);
end $$;

-- 標記某家廠商這個月已付款／取消
create or replace function public.owner_supplier_paid(p_token text, p_supplier_id bigint, p_month date, p_amount numeric)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  m0 date := date_trunc('month', p_month)::date;
begin
  perform public.owner_check(p_token);
  if p_amount is null then
    delete from public.owner_supplier_payments where supplier_id = p_supplier_id and month = m0;
  else
    insert into public.owner_supplier_payments (supplier_id, month, amount, paid_at)
    values (p_supplier_id, m0, round(p_amount), now())
    on conflict (supplier_id, month) do update set amount = excluded.amount, paid_at = now();
  end if;
end $$;


-- ---------------------------------------------------------------------
-- 10. 操作紀錄只有老闆看得到
--     員工只能讀「刪除」的紀錄（垃圾桶要用），看不到新增、修改的紀錄
-- ---------------------------------------------------------------------
drop policy if exists "staff read log" on public.activity_log;
create policy "staff read log" on public.activity_log for select to authenticated
  using ((select public.is_staff()) and action = 'DELETE');

create or replace function public.owner_log(p_token text, p_action text default null, p_before timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.owner_check(p_token);
  return coalesce((
    select jsonb_agg(x order by x.at desc, x.id desc) from (
      select l.id, l.at, l.table_name, l.action, l.old_data, l.new_data, l.device, l.restored_at,
             (select b.plate from public.bikes b
              where b.id = coalesce((l.new_data->>'bike_id')::bigint, (l.old_data->>'bike_id')::bigint)) as plate
      from public.activity_log l
      where (p_action is null or p_action = '' or l.action = p_action)
        and (p_before is null or l.at < p_before)
      order by l.at desc, l.id desc
      limit 100) x), '[]'::jsonb);
end $$;


-- ---------------------------------------------------------------------
-- 權限：網頁可以呼叫，但每個 owner_ 函式都會先檢查老闆通行碼
-- ---------------------------------------------------------------------
revoke execute on function public.owner_orders(text, date), public.owner_set_extra_cost(text, bigint, numeric),
  public.owner_customers(text, int), public.owner_aging(text), public.owner_suppliers(text, date),
  public.owner_supplier_paid(text, bigint, date, numeric), public.owner_log(text, text, timestamptz)
  from public, anon;
grant execute on function public.owner_orders(text, date), public.owner_set_extra_cost(text, bigint, numeric),
  public.owner_customers(text, int), public.owner_aging(text), public.owner_suppliers(text, date),
  public.owner_supplier_paid(text, bigint, date, numeric), public.owner_log(text, text, timestamptz)
  to authenticated;


-- 檢查：兩張新表都要是 true
select tablename, rowsecurity from pg_tables
where schemaname = 'public' and tablename in ('record_extras', 'owner_supplier_payments');
