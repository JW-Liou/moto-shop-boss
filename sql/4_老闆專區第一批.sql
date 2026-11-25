-- =====================================================================
-- 老闆版：老闆專區（成本、毛利）＋ 一批改進
-- 在老闆版的 Supabase 執行一次（前面的 SQL 檔都要先跑過）。可以重複執行。
--
--   1. 垃圾桶救回工單、零件時，庫存也會正確還原
--   2. 預約多一個狀態「沒來」；客人線上預約、取消，店裡會收到提醒
--   3. 客人網站顯示店家資訊（電話、地址、營業時間、地圖）
--   4. 老闆專區：零件進價、其他支出、毛利報表（要輸入老闆密碼）
--      員工共用同一個帳號，所以老闆的資料另外上鎖：表不開放直接讀，
--      只能用老闆密碼換到「通行碼」後，透過 owner_ 開頭的函式讀寫
--   5. 效能：補 3 個索引
--
-- ★ 跑完之後，請另外執行一次下面這行，設定老闆密碼（6 個字以上，自己記好）：
--     select public.owner_init_pin('你的老闆密碼');
--   這行只能在 SQL Editor 跑，網頁上（員工帳號）沒辦法設定，所以員工不能搶先設密碼。
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. 垃圾桶救回時，庫存正確還原
--    刪工單／零件時，連帶刪掉的庫存進出紀錄先存在這裡，救回時一起放回去
-- ---------------------------------------------------------------------
create table if not exists public.deleted_stock_moves (
  id         bigint generated always as identity primary key,
  deleted_at timestamptz not null default now(),
  data       jsonb not null,
  restored   boolean not null default false
);
create index if not exists deleted_stock_moves_at_idx on public.deleted_stock_moves (deleted_at);
alter table public.deleted_stock_moves enable row level security;   -- 沒有規則 = 網頁碰不到
revoke all on public.deleted_stock_moves from anon, authenticated;

create or replace function public.keep_deleted_move()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.deleted_stock_moves (data) values (to_jsonb(old));
  if random() < 0.01 then
    delete from public.deleted_stock_moves where deleted_at < now() - interval '180 days';
  end if;
  return old;
end $$;

drop trigger if exists keep_deleted_moves on public.stock_moves;
create trigger keep_deleted_moves after delete on public.stock_moves
  for each row execute function public.keep_deleted_move();

-- 救回：跟原本一樣，另外處理庫存
--   （要讀上面那張網頁碰不到的表，所以用 security definer；開頭會先確認是員工）
create or replace function public.restore_deleted(log_id bigint)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  l    public.activity_log%rowtype;
  cols text;
  d    public.deleted_stock_moves%rowtype;
  mcols text;
  mv   jsonb;
begin
  if not public.is_staff() then
    raise exception '沒有權限';
  end if;
  select * into l from public.activity_log where id = log_id and action = 'DELETE';
  if not found then
    raise exception '找不到這筆刪除紀錄';
  end if;
  if l.restored_at is not null then
    raise exception '這筆已經救回過了';
  end if;
  if l.table_name not in ('customers', 'bikes', 'service_records', 'appointments', 'parts', 'suppliers') then
    raise exception '這種資料不能救回';
  end if;
  select string_agg(quote_ident(column_name), ', ' order by ordinal_position) into cols
  from information_schema.columns
  where table_schema = 'public' and table_name = l.table_name and is_generated = 'NEVER';

  begin
    execute format(
      'insert into public.%I (%s) overriding system value select %s from jsonb_populate_record(null::public.%I, $1)',
      l.table_name, cols, cols, l.table_name
    ) using case when l.table_name = 'parts'
                 then l.old_data || '{"stock": 0}'::jsonb   -- 零件先從 0 開始，下面放回進出紀錄後數量自然會對
                 else l.old_data end;
  exception
    when foreign_key_violation then
      raise exception '它所屬的車輛或客戶也被刪掉了，請先救回那一筆';
    when unique_violation then
      raise exception '已經有一樣的資料（例如同一個車牌）存在，不能救回';
  end;

  -- 工單、零件：把當時一起刪掉的庫存進出紀錄放回去（庫存會自動重新計算）
  if l.table_name in ('service_records', 'parts') then
    select string_agg(quote_ident(column_name), ', ' order by ordinal_position) into mcols
    from information_schema.columns
    where table_schema = 'public' and table_name = 'stock_moves' and is_generated = 'NEVER';
    for d in
      select * from public.deleted_stock_moves
      where not restored
        and deleted_at = l.at
        and ((l.table_name = 'service_records' and (data->>'record_id')::bigint = l.row_id)
          or (l.table_name = 'parts' and (data->>'part_id')::bigint = l.row_id))
      order by id
    loop
      mv := d.data;
      -- 對應的工單或叫貨單已經不在了，就不連結它
      if mv->>'record_id' is not null and not exists
         (select 1 from public.service_records where id = (mv->>'record_id')::bigint) then
        mv := mv || '{"record_id": null}'::jsonb;
      end if;
      if mv->>'order_id' is not null and not exists
         (select 1 from public.purchase_orders where id = (mv->>'order_id')::bigint) then
        mv := mv || '{"order_id": null}'::jsonb;
      end if;
      -- 零件也不在了（只救回工單、零件還在垃圾桶），這筆先跳過
      if not exists (select 1 from public.parts where id = (mv->>'part_id')::bigint) then
        continue;
      end if;
      begin
        execute format(
          'insert into public.stock_moves (%s) overriding system value select %s from jsonb_populate_record(null::public.stock_moves, $1)',
          mcols, mcols
        ) using mv;
      exception when unique_violation then
        null;   -- 已經在了
      end;
      update public.deleted_stock_moves set restored = true where id = d.id;
    end loop;
  end if;

  update public.activity_log set restored_at = now() where id = log_id;
  update public.activity_log set action = 'RESTORE'
  where id = (select max(id) from public.activity_log
              where table_name = l.table_name and row_id = l.row_id and action = 'INSERT');
  return 'ok';
end $$;


-- ---------------------------------------------------------------------
-- 2. 預約：「沒來」狀態、線上預約提醒
-- ---------------------------------------------------------------------
alter table public.appointments drop constraint if exists appointments_status_check;
alter table public.appointments add constraint appointments_status_check
  check (status in ('預約中', '已到店', '取消', '沒來'));

-- seen_at：店家看過了沒（客人線上預約或取消時會變成空白，看板就會提醒）
alter table public.appointments add column if not exists seen_at timestamptz;
update public.appointments set seen_at = coalesce(seen_at, created_at, now()) where seen_at is null;
create index if not exists appointments_unseen_idx on public.appointments (source) where seen_at is null;

-- 客人取消時，讓店家知道
create or replace function public.cancel_my_booking(p_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  cid bigint := public.my_customer_id();
begin
  if cid is null then
    raise exception '還沒綁定客戶資料';
  end if;
  update public.appointments set status = '取消', seen_at = null
  where id = p_id
    and status = '預約中'
    and date >= public.tw_now()::date
    and plate in (select plate from public.bikes where customer_id = cid);
  if not found then
    raise exception '找不到這個預約，可能已經取消或過期了';
  end if;
end $$;

-- 線上預約：半年內「沒來」3 次以上的，請他打電話預約（其他規則跟原本一樣）
create or replace function public.book_online(p_bike_id bigint, p_date date, p_time time, p_items text default null)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  cid  bigint := public.my_customer_id();
  bk   public.bikes%rowtype;
  cu   public.customers%rowtype;
  ok   boolean;
  new_id bigint;
begin
  if cid is null then
    raise exception '還沒綁定客戶資料';
  end if;
  select * into bk from public.bikes where id = p_bike_id and customer_id = cid;
  if not found then
    raise exception '找不到這台車';
  end if;
  if length(coalesce(p_items, '')) > 100 then
    raise exception '想做的項目請寫短一點（100 字以內）';
  end if;
  if (select count(*) from public.appointments a
      join public.bikes b on b.plate = a.plate
      where b.customer_id = cid and a.status = '沒來'
        and a.date > public.tw_now()::date - 180) >= 3 then
    raise exception '最近幾次預約都沒有到店，線上預約先暫停，請直接打電話跟我們約喔';
  end if;

  perform pg_advisory_xact_lock(hashtext('booking ' || p_date || ' ' || p_time));

  select exists (
    select 1 from public.available_slots(p_date, 1) s
    where s.date = p_date and s.slot_time = p_time
      and not s.closed and s.remaining > 0
  ) into ok;
  if not ok or not (select enabled from public.booking_settings where id = 1)
     or p_date >= public.tw_now()::date + (select days_ahead from public.booking_settings where id = 1)
     or p_date + p_time <= public.tw_now() + make_interval(hours => (select min_hours_ahead from public.booking_settings where id = 1)) then
    raise exception '這個時段已經約滿或不開放了，請選別的時段';
  end if;

  if exists (select 1 from public.appointments
             where plate = bk.plate and date = p_date and status = '預約中') then
    raise exception '這台車那天已經有預約了';
  end if;
  if (select count(*) from public.appointments a
      join public.bikes b on b.plate = a.plate
      where b.customer_id = cid and a.status = '預約中' and a.date >= public.tw_now()::date) >= 3 then
    raise exception '已經有 3 個還沒到的預約，請先到店或取消再約';
  end if;

  select * into cu from public.customers where id = cid;
  insert into public.appointments (date, time, plate, name, phone, items, status, source, seen_at)
  values (p_date, p_time, bk.plate, cu.name, cu.phone, nullif(trim(p_items), ''), '預約中', '線上', null)
  returning id into new_id;
  return new_id;
end $$;


-- ---------------------------------------------------------------------
-- 3. 店家資訊（顯示在客人網站）
-- ---------------------------------------------------------------------
alter table public.booking_settings add column if not exists shop_phone   text;
alter table public.booking_settings add column if not exists shop_address text;
alter table public.booking_settings add column if not exists shop_hours   text;
alter table public.booking_settings add column if not exists map_url      text;

-- 沒登入也看得到（本來就是公開的店家資訊）
create or replace function public.shop_info()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('phone', shop_phone, 'address', shop_address,
                            'hours', shop_hours, 'map_url', map_url)
  from public.booking_settings where id = 1
$$;
revoke execute on function public.shop_info() from public;
grant execute on function public.shop_info() to anon, authenticated;


-- ---------------------------------------------------------------------
-- 4. 老闆專區：進價、其他支出、毛利
--    這些表「完全不開放」給網頁直接讀，員工帳號查不到；
--    只能透過下面的 owner_ 函式，而且每次都要帶老闆密碼
-- ---------------------------------------------------------------------
create table if not exists public.owner_settings (
  id           int primary key default 1 check (id = 1),
  pin_hash     text,
  failed       int not null default 0,
  locked_until timestamptz
);
insert into public.owner_settings (id) values (1) on conflict (id) do nothing;

create table if not exists public.part_costs (
  part_id    bigint primary key references public.parts(id) on delete cascade,
  cost       numeric(10, 2) not null check (cost >= 0),
  updated_at timestamptz not null default now()
);

-- 每一筆用掉的零件，當時的進價（之後改進價不會影響以前的毛利）
create table if not exists public.move_costs (
  move_id   bigint primary key references public.stock_moves(id) on delete cascade,
  unit_cost numeric(10, 2) not null
);

create table if not exists public.owner_expenses (
  id         bigint generated always as identity primary key,
  date       date not null,
  category   text not null,
  item       text,
  amount     numeric(12, 0) not null check (amount >= 0),
  created_at timestamptz not null default now()
);
create index if not exists owner_expenses_date_idx on public.owner_expenses (date);

alter table public.owner_settings enable row level security;
alter table public.part_costs     enable row level security;
alter table public.move_costs     enable row level security;
alter table public.owner_expenses enable row level security;
revoke all on public.owner_settings, public.part_costs, public.move_costs, public.owner_expenses
  from anon, authenticated;

-- 用掉零件時，自動記下當時的進價
create or replace function public.record_move_cost()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  c numeric;
begin
  if new.change < 0 or new.reason = '工單使用' then
    select cost into c from public.part_costs where part_id = new.part_id;
    if c is not null then
      insert into public.move_costs (move_id, unit_cost) values (new.id, c)
      on conflict (move_id) do nothing;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists record_move_cost on public.stock_moves;
create trigger record_move_cost after insert on public.stock_moves
  for each row execute function public.record_move_cost();

-- 開鎖後拿到的通行碼（只存雜湊），30 分鐘沒動作就失效
create table if not exists public.owner_sessions (
  token_hash text primary key,
  expires_at timestamptz not null
);
alter table public.owner_sessions enable row level security;
revoke all on public.owner_sessions from anon, authenticated;

-- 設定老闆密碼（第一次）：只能在 SQL Editor 跑
create or replace function public.owner_init_pin(p_pin text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
begin
  if length(coalesce(p_pin, '')) < 6 then
    raise exception '老闆密碼至少 6 個字';
  end if;
  update public.owner_settings
  set pin_hash = extensions.crypt(p_pin, extensions.gen_salt('bf')), failed = 0, locked_until = null
  where id = 1;
  delete from public.owner_sessions;
  return '老闆密碼設定好了';
end $$;
revoke execute on function public.owner_init_pin(text) from public, anon, authenticated;

-- 開鎖：密碼對就發一個通行碼；錯 5 次鎖 15 分鐘
create or replace function public.owner_unlock(p_pin text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.owner_settings%rowtype;
  tok text;
begin
  if not public.is_staff() then
    raise exception '沒有權限';
  end if;
  select * into s from public.owner_settings where id = 1 for update;
  if s.pin_hash is null then
    raise exception '還沒設定老闆密碼，請在 Supabase 的 SQL Editor 執行 owner_init_pin（看設定說明）';
  end if;
  if s.locked_until is not null and s.locked_until > now() then
    raise exception '密碼錯太多次，請 % 分鐘後再試',
      ceil(extract(epoch from s.locked_until - now()) / 60);
  end if;
  if extensions.crypt(coalesce(p_pin, ''), s.pin_hash) <> s.pin_hash then
    update public.owner_settings
    set failed = failed + 1,
        locked_until = case when failed + 1 >= 5 then now() + interval '15 minutes' end
    where id = 1;
    return null;   -- 不丟錯誤，錯誤次數才會真的存進去
  end if;
  update public.owner_settings set failed = 0, locked_until = null where id = 1;
  delete from public.owner_sessions where expires_at < now();
  tok := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.owner_sessions (token_hash, expires_at)
  values (encode(extensions.digest(tok, 'sha256'), 'hex'), now() + interval '30 minutes');
  return tok;
end $$;

-- 每個老闆功能都先檢查通行碼（有用就再延長 30 分鐘）
create or replace function public.owner_check(p_token text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_staff() then
    raise exception '沒有權限';
  end if;
  update public.owner_sessions set expires_at = now() + interval '30 minutes'
  where token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex')
    and expires_at > now();
  if not found then
    raise exception '老闆專區已上鎖，請重新輸入老闆密碼';
  end if;
end $$;

-- 上鎖
create or replace function public.owner_lock(p_token text)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.owner_sessions
  where token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex')
$$;

-- 改老闆密碼（要已開鎖，再加上舊密碼）
create or replace function public.owner_change_pin(p_token text, p_old text, p_new text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  h text;
begin
  perform public.owner_check(p_token);
  select pin_hash into h from public.owner_settings where id = 1;
  if extensions.crypt(coalesce(p_old, ''), h) <> h then
    raise exception '舊密碼不對';
  end if;
  if length(coalesce(p_new, '')) < 6 then
    raise exception '新密碼至少 6 個字';
  end if;
  update public.owner_settings
  set pin_hash = extensions.crypt(p_new, extensions.gen_salt('bf')) where id = 1;
  delete from public.owner_sessions;   -- 其他開著的老闆專區全部上鎖
  return '已更換老闆密碼，請用新密碼重新開鎖';
end $$;

-- 零件清單＋進價
create or replace function public.owner_parts(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.owner_check(p_token);
  return coalesce((select jsonb_agg(x order by x.category, x.name, x.spec) from (
    select p.id, p.name, p.spec, p.category, p.unit, p.stock, p.price, p.active,
           c.cost, c.updated_at as cost_updated
    from public.parts p left join public.part_costs c on c.part_id = p.id) x), '[]'::jsonb);
end $$;

-- 設定進價；p_backfill = 也補到以前「沒有記到進價」的用量上
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
    where m.part_id = p_part_id and (m.change < 0 or m.reason = '工單使用')
      and not exists (select 1 from public.move_costs mc where mc.move_id = m.id);
    get diagnostics n = row_count;
  end if;
  return n;
end $$;

-- 其他支出
create or replace function public.owner_expense_add(p_token text, p_date date, p_category text, p_item text, p_amount numeric)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  new_id bigint;
begin
  perform public.owner_check(p_token);
  if p_date is null or coalesce(trim(p_category), '') = '' or p_amount is null or p_amount < 0 then
    raise exception '日期、類別、金額都要填，金額不能是負的';
  end if;
  insert into public.owner_expenses (date, category, item, amount)
  values (p_date, trim(p_category), nullif(trim(p_item), ''), round(p_amount))
  returning id into new_id;
  return new_id;
end $$;

create or replace function public.owner_expense_delete(p_token text, p_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.owner_check(p_token);
  delete from public.owner_expenses where id = p_id;
end $$;

-- 報表：某個月的明細＋最近 12 個月的趨勢
--   營收：已完成工單的金額（以完成那天算）
--   零件成本：這些工單用掉的零件 × 當時進價
--   其他支出：自己記的（代工、房租、水電、薪資…）
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
          coalesce((select sum(r.total) from public.service_records r
            where r.status = '已完成'
              and (r.completed_at at time zone 'Asia/Taipei') >= mm
              and (r.completed_at at time zone 'Asia/Taipei') < mm + interval '1 month'), 0) as revenue,
          coalesce((select sum(-m.change * mc.unit_cost) from public.stock_moves m
            join public.move_costs mc on mc.move_id = m.id
            join public.service_records r on r.id = m.record_id
            where m.reason = '工單使用' and r.status = '已完成'
              and (r.completed_at at time zone 'Asia/Taipei') >= mm
              and (r.completed_at at time zone 'Asia/Taipei') < mm + interval '1 month'), 0) as parts_cost,
          coalesce((select sum(e.amount) from public.owner_expenses e
            where e.date >= mm and e.date < mm + interval '1 month'), 0) as expenses
        from generate_series(m0 - interval '11 months', m0, interval '1 month') mm
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
      select count(distinct m.part_id) from public.stock_moves m
      join public.service_records r on r.id = m.record_id
      left join public.move_costs mc on mc.move_id = m.id
      where m.reason = '工單使用' and mc.move_id is null and r.status = '已完成'
        and (r.completed_at at time zone 'Asia/Taipei') >= m0
        and (r.completed_at at time zone 'Asia/Taipei') < m1),
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

-- 網頁（員工帳號）可以呼叫這些函式，但每個函式裡面都會先檢查老闆通行碼
revoke execute on function public.owner_check(text) from public, anon, authenticated;
revoke execute on function public.owner_unlock(text), public.owner_lock(text),
  public.owner_change_pin(text, text, text),
  public.owner_parts(text), public.owner_set_cost(text, bigint, numeric, boolean),
  public.owner_expense_add(text, date, text, text, numeric), public.owner_expense_delete(text, bigint),
  public.owner_report(text, date) from public, anon;
grant execute on function public.owner_unlock(text), public.owner_lock(text),
  public.owner_change_pin(text, text, text),
  public.owner_parts(text), public.owner_set_cost(text, bigint, numeric, boolean),
  public.owner_expense_add(text, date, text, text, numeric), public.owner_expense_delete(text, bigint),
  public.owner_report(text, date) to authenticated;
revoke execute on function public.keep_deleted_move(), public.record_move_cost() from public, anon, authenticated;
revoke execute on function public.restore_deleted(bigint) from public, anon;
grant execute on function public.restore_deleted(bigint) to authenticated;


-- ---------------------------------------------------------------------
-- 5. 效能：Supabase 建議補的索引
-- ---------------------------------------------------------------------
create index if not exists purchase_order_items_part_idx on public.purchase_order_items (part_id);
create index if not exists purchase_orders_supplier_idx  on public.purchase_orders (supplier_id);
create index if not exists stock_moves_order_idx         on public.stock_moves (order_id);


-- ---------------------------------------------------------------------
-- 檢查：老闆專區的表，網頁直接讀應該都「沒有權限」
-- ---------------------------------------------------------------------
select tablename, rowsecurity from pg_tables
where schemaname = 'public'
  and tablename in ('owner_settings', 'owner_sessions', 'part_costs', 'move_costs', 'owner_expenses', 'deleted_stock_moves');
