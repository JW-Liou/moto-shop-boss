-- =====================================================================
-- 老闆版：老闆專區第三批（先跑過第二批再跑這個；可以重複執行）
--
--   1. 工單毛利：可以自己選日期區間
--   2. 大客戶排行：可以自己選日期區間
--   3. 先登記「還沒進的零件」的進價：
--      之後在「庫存」新增一樣品名＋規格的零件時，進價會自動帶進去
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. 工單毛利：日期區間（沒給就是整個月）
-- ---------------------------------------------------------------------
drop function if exists public.owner_orders(text, date);
create or replace function public.owner_orders(p_token text, p_month date default null,
                                               p_from date default null, p_to date default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  m0 date := date_trunc('month', coalesce(p_month, public.tw_now()::date))::date;
  d1 date := coalesce(p_from, m0);
  d2 date := coalesce(p_to, (m0 + interval '1 month')::date - 1);
begin
  perform public.owner_check(p_token);
  if d2 < d1 then
    raise exception '結束日期要在開始日期之後';
  end if;
  if d2 - d1 > 800 then
    raise exception '一次最多查兩年';
  end if;
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
      from public.owner_record_numbers(d1, d2) n
      join public.service_records r on r.id = n.record_id
      join public.bikes b on b.id = n.bike_id
      left join public.customers c on c.id = b.customer_id) x), '[]'::jsonb);
end $$;


-- ---------------------------------------------------------------------
-- 2. 大客戶排行：日期區間（沒給就是最近 12 個月）
-- ---------------------------------------------------------------------
drop function if exists public.owner_customers(text, int);
create or replace function public.owner_customers(p_token text, p_from date default null, p_to date default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  d2 date := coalesce(p_to, public.tw_now()::date);
  d1 date := coalesce(p_from, (d2 - interval '12 months')::date + 1);
begin
  perform public.owner_check(p_token);
  if d2 < d1 then
    raise exception '結束日期要在開始日期之後';
  end if;
  return jsonb_build_object(
    'since', d1,
    'until', d2,
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
        where r.status = '已完成'
          and (r.completed_at at time zone 'Asia/Taipei')::date between d1 and d2
        group by c.id, c.name
        order by sum(r.total) desc
        limit 20) x), '[]'::jsonb),
    'total_customers', (
      select count(distinct b.customer_id) from public.service_records r
      join public.bikes b on b.id = r.bike_id
      where r.status = '已完成' and (r.completed_at at time zone 'Asia/Taipei')::date between d1 and d2),
    'total_spent', (
      select coalesce(sum(r.total), 0) from public.service_records r
      where r.status = '已完成' and (r.completed_at at time zone 'Asia/Taipei')::date between d1 and d2)
  );
end $$;


-- ---------------------------------------------------------------------
-- 3. 還沒進的零件，先登記進價
--    比對方式：品名、規格去掉空白、大小寫不分，一模一樣才算
-- ---------------------------------------------------------------------
create table if not exists public.pending_costs (
  id         bigint generated always as identity primary key,
  name       text not null,
  spec       text,
  cost       numeric(10, 2) not null check (cost >= 0),
  created_at timestamptz not null default now(),
  matched_part_id bigint,          -- 不設外鍵：清除模擬資料（清空零件）時，這些登記不會被一起清掉
  matched_at timestamptz
);
alter table public.pending_costs drop constraint if exists pending_costs_matched_part_id_fkey;
alter table public.pending_costs enable row level security;
revoke all on public.pending_costs from anon, authenticated;

create or replace function public.part_key(p_name text, p_spec text)
returns text
language sql
immutable
set search_path = ''
as $$ select lower(regexp_replace(coalesce(p_name, ''), '\s', '', 'g')) || '|' ||
             lower(regexp_replace(coalesce(p_spec, ''), '\s', '', 'g')) $$;

-- 庫存新增零件（或改品名、規格）時：有先登記的進價就自動帶入
create or replace function public.apply_pending_cost()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  pc public.pending_costs%rowtype;
begin
  if exists (select 1 from public.part_costs where part_id = new.id) then
    return new;
  end if;
  select * into pc from public.pending_costs
  where matched_part_id is null and public.part_key(name, spec) = public.part_key(new.name, new.spec)
  order by id desc limit 1;
  if found then
    insert into public.part_costs (part_id, cost, updated_at) values (new.id, pc.cost, now())
    on conflict (part_id) do nothing;
    update public.pending_costs set matched_part_id = new.id, matched_at = now() where id = pc.id;
  end if;
  return new;
end $$;
drop trigger if exists apply_pending_cost on public.parts;
create trigger apply_pending_cost after insert or update of name, spec on public.parts
  for each row execute function public.apply_pending_cost();
revoke execute on function public.apply_pending_cost() from public, anon, authenticated;

create or replace function public.owner_pending_list(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.owner_check(p_token);
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', pc.id, 'name', pc.name, 'spec', pc.spec, 'cost', pc.cost,
             'created_at', pc.created_at, 'matched_at', pc.matched_at,
             'matched_part', case when p.id is not null then p.name || coalesce(' ' || p.spec, '') end)
           order by pc.matched_at nulls first, pc.id desc)
    from public.pending_costs pc left join public.parts p on p.id = pc.matched_part_id), '[]'::jsonb);
end $$;

create or replace function public.owner_pending_add(p_token text, p_name text, p_spec text, p_cost numeric)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  part_id_found bigint;
begin
  perform public.owner_check(p_token);
  if coalesce(trim(p_name), '') = '' then
    raise exception '請填品名';
  end if;
  if p_cost is null or p_cost < 0 or p_cost > 1000000 then
    raise exception '進價不合理';
  end if;
  -- 庫存裡其實已經有了：直接設定進價
  select id into part_id_found from public.parts
  where public.part_key(name, spec) = public.part_key(p_name, p_spec) limit 1;
  if part_id_found is not null then
    insert into public.part_costs (part_id, cost, updated_at) values (part_id_found, p_cost, now())
    on conflict (part_id) do update set cost = excluded.cost, updated_at = now();
    return '庫存裡已經有這個零件，進價直接設定好了';
  end if;
  delete from public.pending_costs
  where matched_part_id is null and public.part_key(name, spec) = public.part_key(p_name, p_spec);
  insert into public.pending_costs (name, spec, cost)
  values (trim(p_name), nullif(trim(coalesce(p_spec, '')), ''), p_cost);
  return '已登記，之後庫存新增「' || trim(p_name) || coalesce(' ' || nullif(trim(coalesce(p_spec, '')), ''), '') || '」時會自動帶入進價';
end $$;

create or replace function public.owner_pending_delete(p_token text, p_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.owner_check(p_token);
  delete from public.pending_costs where id = p_id;
end $$;


-- ---------------------------------------------------------------------
-- 權限
-- ---------------------------------------------------------------------
revoke execute on function public.owner_orders(text, date, date, date), public.owner_customers(text, date, date),
  public.owner_pending_list(text), public.owner_pending_add(text, text, text, numeric),
  public.owner_pending_delete(text, bigint) from public, anon;
grant execute on function public.owner_orders(text, date, date, date), public.owner_customers(text, date, date),
  public.owner_pending_list(text), public.owner_pending_add(text, text, text, numeric),
  public.owner_pending_delete(text, bigint) to authenticated;

select tablename, rowsecurity from pg_tables where schemaname = 'public' and tablename = 'pending_costs';
