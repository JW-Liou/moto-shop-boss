-- =====================================================================
-- 老闆版：客人網站（線上預約、查保養紀錄）＋ AI 小助理
-- 在老闆版的 Supabase 執行一次（要先跑過「sql/1_全新資料庫.sql」和「sql/2_庫存.sql」）
-- 可以重複執行，不會出錯
--
-- 新增的表：
--   booking_settings   線上預約的開關、可以預約幾天內、最晚幾小時前
--   booking_slots      每週固定開放的時段（例如：週一 10:00 可以約 2 台）
--   booking_blocks     臨時關掉的日期或時段（例如：12/24 整天公休、12/25 14:00 不開放）
--   customer_accounts  客人的 LINE 帳號綁到哪一位客戶
--   bind_codes         店家產生的綁定碼（客人輸入後完成綁定，7 天內有效、只能用一次）
--   bind_attempts      綁定碼輸入錯誤的次數（防止有人亂猜）
--
-- 客人「不能」直接讀任何資料表，只能透過下面的函式：
--   available_slots()   看還有哪些時段可以約（不含任何客人資料）
--   bind_customer()     輸入綁定碼，把自己的 LINE 帳號綁到客戶資料
--   my_info()           看自己的車、保養紀錄（含金額）、預約
--   book_online()       線上預約
--   cancel_my_booking() 取消自己的預約
-- 每個函式都只會用「登入者自己綁定的客戶」去查，看不到別人的資料
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. 線上預約時段
-- ---------------------------------------------------------------------
create table if not exists public.booking_settings (
  id              int primary key default 1 check (id = 1),     -- 只會有一列
  enabled         boolean not null default true,                -- 關掉就整個暫停線上預約
  days_ahead      int not null default 14 check (days_ahead between 1 and 60),   -- 可以預約幾天內
  min_hours_ahead int not null default 2  check (min_hours_ahead between 0 and 72), -- 最晚要幾小時前約
  notice          text                                           -- 顯示在客人預約頁的說明
);
insert into public.booking_settings (id, notice)
values (1, '預約後請準時到店，臨時不能來請在網站上取消，或打電話告訴我們。')
on conflict (id) do nothing;

create table if not exists public.booking_slots (
  id        bigint generated always as identity primary key,
  weekday   int  not null check (weekday between 0 and 6),   -- 0 = 週日，1 = 週一 … 6 = 週六
  slot_time time not null,
  capacity  int  not null default 1 check (capacity between 1 and 20),  -- 這個時段最多幾台
  unique (weekday, slot_time)
);

create table if not exists public.booking_blocks (
  id         bigint generated always as identity primary key,
  date       date not null,
  slot_time  time,                 -- 空白 = 整天不開放
  reason     text,
  created_at timestamptz not null default now(),
  unique nulls not distinct (date, slot_time)
);
create index if not exists booking_blocks_date_idx on public.booking_blocks (date);
create index if not exists appointments_date_time_idx on public.appointments (date, time);

-- 預設時段：週一到週六 10:00、11:00、14:00、15:00、16:00、17:00，每個時段 1 台（之後在網頁上改）
insert into public.booking_slots (weekday, slot_time, capacity)
select w, t::time, 1
from generate_series(1, 6) w,
     unnest(array['10:00', '11:00', '14:00', '15:00', '16:00', '17:00']) t
where not exists (select 1 from public.booking_slots)
on conflict do nothing;


-- ---------------------------------------------------------------------
-- 2. 客人帳號綁定
-- ---------------------------------------------------------------------
create table if not exists public.customer_accounts (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  customer_id  bigint not null references public.customers(id) on delete cascade,
  display_name text,                       -- LINE 上的名字
  created_at   timestamptz not null default now()
);
create index if not exists customer_accounts_customer_idx on public.customer_accounts (customer_id);

create table if not exists public.bind_codes (
  code        text primary key,
  customer_id bigint not null references public.customers(id) on delete cascade,
  expires_at  timestamptz not null default now() + interval '7 days',
  used_at     timestamptz,
  created_at  timestamptz not null default now()
);
create index if not exists bind_codes_customer_idx on public.bind_codes (customer_id);

create table if not exists public.bind_attempts (
  id      bigint generated always as identity primary key,
  user_id uuid not null,
  at      timestamptz not null default now()
);
create index if not exists bind_attempts_user_idx on public.bind_attempts (user_id, at);


-- ---------------------------------------------------------------------
-- 3. 門禁：這些表只有員工能直接讀寫；客人只能用第 4 段的函式
-- ---------------------------------------------------------------------
alter table public.booking_settings  enable row level security;
alter table public.booking_slots     enable row level security;
alter table public.booking_blocks    enable row level security;
alter table public.customer_accounts enable row level security;
alter table public.bind_codes        enable row level security;
alter table public.bind_attempts     enable row level security;   -- 沒有任何規則 = 網頁完全碰不到

drop policy if exists "staff only" on public.booking_settings;
create policy "staff only" on public.booking_settings for all to authenticated
  using ((select public.is_staff())) with check ((select public.is_staff()));
drop policy if exists "staff only" on public.booking_slots;
create policy "staff only" on public.booking_slots for all to authenticated
  using ((select public.is_staff())) with check ((select public.is_staff()));
drop policy if exists "staff only" on public.booking_blocks;
create policy "staff only" on public.booking_blocks for all to authenticated
  using ((select public.is_staff())) with check ((select public.is_staff()));
drop policy if exists "staff only" on public.customer_accounts;
create policy "staff only" on public.customer_accounts for all to authenticated
  using ((select public.is_staff())) with check ((select public.is_staff()));
drop policy if exists "staff only" on public.bind_codes;
create policy "staff only" on public.bind_codes for all to authenticated
  using ((select public.is_staff())) with check ((select public.is_staff()));

grant select, insert, update, delete on public.booking_settings, public.booking_slots,
  public.booking_blocks, public.customer_accounts, public.bind_codes to authenticated;
revoke all on public.bind_attempts from anon, authenticated;


-- ---------------------------------------------------------------------
-- 4. 函式
-- ---------------------------------------------------------------------

-- 台灣現在的時間（資料庫主機是 UTC）
create or replace function public.tw_now()
returns timestamp
language sql
stable
set search_path = ''
as $$ select (now() at time zone 'Asia/Taipei') $$;

-- 登入的客人綁定的是哪一位客戶（沒綁定就是空的）
create or replace function public.my_customer_id()
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select customer_id from public.customer_accounts where user_id = auth.uid()
$$;

-- 還可以預約的時段（員工和客人都能用；不含任何客人資料，只有剩幾個名額）
create or replace function public.available_slots(p_from date default null, p_days int default null)
returns table (date date, slot_time time, capacity int, booked int, remaining int, closed boolean)
language sql
stable
security definer
set search_path = ''
as $$
  with s as (
    select * from public.booking_settings where id = 1
  ),
  days as (
    select g::date as d
    from s, generate_series(
      coalesce(p_from, public.tw_now()::date),
      coalesce(p_from, public.tw_now()::date) + least(coalesce(p_days, s.days_ahead), 60) - 1,
      interval '1 day') g
  ),
  slots as (
    select days.d, b.slot_time, b.capacity,
      (select count(*)::int from public.appointments a
        where a.date = days.d and a.time = b.slot_time and a.status <> '取消') as booked,
      exists (select 1 from public.booking_blocks k
        where k.date = days.d and (k.slot_time is null or k.slot_time = b.slot_time)) as closed
    from days
    join public.booking_slots b on b.weekday = extract(dow from days.d)
  )
  select slots.d, slots.slot_time, slots.capacity, slots.booked,
         greatest(slots.capacity - slots.booked, 0), slots.closed
  from slots, s
  where
    -- 員工看得到全部（包含關掉的、額滿的），方便管理
    public.is_staff()
    -- 客人只看得到：線上預約有開、在可預約天數內、沒被關掉、還有名額、離現在夠久
    or (s.enabled
        and slots.d < public.tw_now()::date + s.days_ahead
        and not slots.closed
        and slots.capacity > slots.booked
        and slots.d + slots.slot_time > public.tw_now() + make_interval(hours => s.min_hours_ahead))
  order by 1, 2;
$$;

-- 員工：幫某位客戶產生綁定碼（8 碼，不含容易看錯的 0 O 1 I L）
create or replace function public.create_bind_code(p_customer_id bigint)
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  chars text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  c text;
begin
  if not public.is_staff() then
    raise exception '沒有權限';
  end if;
  -- 同一位客戶還沒用掉的舊碼作廢，只留最新的
  delete from public.bind_codes where customer_id = p_customer_id and used_at is null;
  loop
    select string_agg(substr(chars, 1 + floor(random() * length(chars))::int, 1), '')
      into c from generate_series(1, 8);
    begin
      insert into public.bind_codes (code, customer_id) values (c, p_customer_id);
      exit;
    exception when unique_violation then
      -- 剛好重複就再產生一次
    end;
  end loop;
  return c;
end $$;

-- 客人：輸入綁定碼
create or replace function public.bind_customer(p_code text, p_display_name text default null)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid  uuid := auth.uid();
  b    public.bind_codes%rowtype;
  cname text;
begin
  if uid is null then
    raise exception '請先登入';
  end if;
  -- 1 小時內輸錯 10 次就先擋住
  if (select count(*) from public.bind_attempts
      where user_id = uid and at > now() - interval '1 hour') >= 10 then
    raise exception '輸入錯誤太多次，請 1 小時後再試，或請店家重新產生綁定碼';
  end if;

  select * into b from public.bind_codes
  where code = upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g'))
  for update;
  if not found or b.used_at is not null or b.expires_at < now() then
    insert into public.bind_attempts (user_id) values (uid);
    if random() < 0.05 then
      delete from public.bind_attempts where at < now() - interval '1 day';
    end if;
    raise exception '綁定碼不正確或已經過期，請跟店家要新的綁定碼';
  end if;

  insert into public.customer_accounts (user_id, customer_id, display_name)
  values (uid, b.customer_id, left(p_display_name, 50))
  on conflict (user_id) do update
    set customer_id = excluded.customer_id, display_name = excluded.display_name;
  update public.bind_codes set used_at = now() where code = b.code;

  select name into cname from public.customers where id = b.customer_id;
  return cname;
end $$;

-- 客人：看自己的資料（車、保養紀錄含金額、預約）
create or replace function public.my_info()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  cid bigint := public.my_customer_id();
begin
  if cid is null then
    return jsonb_build_object('bound', false);
  end if;
  return jsonb_build_object(
    'bound', true,
    'name', (select name from public.customers where id = cid),
    'bikes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', b.id, 'plate', b.plate, 'model', b.model, 'year', b.year, 'mileage', b.mileage
      ) order by b.id)
      from public.bikes b where b.customer_id = cid), '[]'::jsonb),
    'records', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', r.id, 'plate', b.plate, 'date', r.date, 'mileage', r.mileage,
        'items', r.items, 'parts', r.parts, 'total', r.total, 'status', r.status,
        'next_service_km', r.next_service_km
      ) order by r.date desc, r.id desc)
      from public.service_records r
      join public.bikes b on b.id = r.bike_id
      where b.customer_id = cid), '[]'::jsonb),
    'appointments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', a.id, 'date', a.date, 'time', a.time, 'plate', a.plate,
        'items', a.items, 'status', a.status, 'source', a.source
      ) order by a.date, a.time)
      from public.appointments a
      where a.plate in (select plate from public.bikes where customer_id = cid)
        and a.date >= public.tw_now()::date
        and a.status = '預約中'), '[]'::jsonb),
    'notice', (select notice from public.booking_settings where id = 1),
    'booking_enabled', coalesce((select enabled from public.booking_settings where id = 1), false)
  );
end $$;

-- 客人：線上預約
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

  -- 同一個時段一次只讓一個人搶，避免兩個人同時約到最後一個名額
  perform pg_advisory_xact_lock(hashtext('booking ' || p_date || ' ' || p_time));

  select exists (
    select 1 from public.available_slots(p_date, 1) s
    where s.date = p_date and s.slot_time = p_time
      and not s.closed and s.remaining > 0
  ) into ok;
  -- available_slots 對員工會回傳全部，所以這裡再檢查一次規則
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
  insert into public.appointments (date, time, plate, name, phone, items, status, source)
  values (p_date, p_time, bk.plate, cu.name, cu.phone, nullif(trim(p_items), ''), '預約中', '線上')
  returning id into new_id;
  return new_id;
end $$;

-- 客人：取消自己的預約
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
  update public.appointments set status = '取消'
  where id = p_id
    and status = '預約中'
    and date >= public.tw_now()::date
    and plate in (select plate from public.bikes where customer_id = cid);
  if not found then
    raise exception '找不到這個預約，可能已經取消或過期了';
  end if;
end $$;

-- 誰能呼叫：未登入的人一個都不能用；登入的人才能用（函式裡面自己會再檢查身分）
revoke execute on function public.my_customer_id()                       from public, anon;
revoke execute on function public.available_slots(date, int)              from public, anon;
revoke execute on function public.create_bind_code(bigint)                from public, anon;
revoke execute on function public.bind_customer(text, text)               from public, anon;
revoke execute on function public.my_info()                               from public, anon;
revoke execute on function public.book_online(bigint, date, time, text)   from public, anon;
revoke execute on function public.cancel_my_booking(bigint)               from public, anon;
grant execute on function public.my_customer_id(), public.available_slots(date, int),
  public.create_bind_code(bigint), public.bind_customer(text, text), public.my_info(),
  public.book_online(bigint, date, time, text), public.cancel_my_booking(bigint), public.tw_now()
  to authenticated;


-- ---------------------------------------------------------------------
-- 5. AI 小助理查資料用的函式
--    小助理（Supabase 上的 Edge Function）用「登入員工自己的權限」呼叫它，
--    所以門禁照樣有效：不是員工就什麼都查不到
--    回傳的資料「不含電話」，因為會送給 Google Gemini
-- ---------------------------------------------------------------------
create or replace function public.assistant_tool(p_name text, p_args jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  d1 date;
  d2 date;
  q  text;
  v_plate text;
  res jsonb;
begin
  if not public.is_staff() then
    raise exception '沒有權限';
  end if;
  p_args := coalesce(p_args, '{}'::jsonb);

  -- 今天或某一天的概況：來客、完成幾筆、營收、預約、還沒修好的工單
  if p_name = 'day_overview' then
    d1 := coalesce(nullif(p_args->>'date', '')::date, public.tw_now()::date);
    return jsonb_build_object(
      'date', d1,
      'visitors', (select count(distinct bike_id) from public.service_records where date = d1),
      'orders_opened', (select count(*) from public.service_records where date = d1),
      'completed', (select count(*) from public.service_records
                    where status = '已完成' and (completed_at at time zone 'Asia/Taipei')::date = d1),
      'revenue', (select coalesce(sum(total), 0) from public.service_records
                  where status = '已完成' and (completed_at at time zone 'Asia/Taipei')::date = d1),
      'appointments', (select count(*) from public.appointments where date = d1 and status <> '取消'),
      'waiting', (select count(*) from public.service_records where status = '待修'),
      'in_progress', (select count(*) from public.service_records where status = '維修中')
    );

  -- 一段期間的來客數和營收
  elsif p_name = 'period_stats' then
    d1 := (p_args->>'from')::date;
    d2 := coalesce(nullif(p_args->>'to', '')::date, public.tw_now()::date);
    if d1 is null then raise exception '缺少開始日期'; end if;
    return jsonb_build_object(
      'from', d1, 'to', d2,
      'visitors', (select count(*) from (select distinct bike_id, date from public.service_records
                    where date between d1 and d2) v),
      'completed', (select count(*) from public.service_records
                    where status = '已完成' and (completed_at at time zone 'Asia/Taipei')::date between d1 and d2),
      'revenue', (select coalesce(sum(total), 0) from public.service_records
                  where status = '已完成' and (completed_at at time zone 'Asia/Taipei')::date between d1 and d2),
      'top_items', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
                      select items, count(*) as times from public.service_records
                      where date between d1 and d2 group by items order by 2 desc limit 8) x)
    );

  -- 用車牌查一台車：車主姓名、車型、最近的維修紀錄、接下來的預約
  elsif p_name = 'find_bike' then
    v_plate := upper(regexp_replace(coalesce(p_args->>'plate', ''), '[^A-Za-z0-9]', '', 'g'));
    if v_plate = '' then raise exception '缺少車牌'; end if;
    select jsonb_build_object(
      'plate', b.plate, 'model', b.model, 'year', b.year, 'mileage', b.mileage,
      'owner', c.name,
      'records', coalesce((select jsonb_agg(x) from (
          select r.date, r.mileage, r.items, r.parts, r.total, r.status, r.next_service_km
          from public.service_records r where r.bike_id = b.id
          order by r.date desc, r.id desc limit 8) x), '[]'::jsonb),
      'upcoming_appointments', coalesce((select jsonb_agg(x) from (
          select a.date, a.time, a.items from public.appointments a
          where a.plate = b.plate and a.status = '預約中' and a.date >= public.tw_now()::date
          order by a.date, a.time) x), '[]'::jsonb)
    ) into res
    from public.bikes b left join public.customers c on c.id = b.customer_id
    where b.plate = v_plate;
    -- 打不完整也試著找找看
    if res is null then
      select jsonb_build_object('not_found', true, 'similar_plates',
               coalesce(jsonb_agg(b.plate), '[]'::jsonb)) into res
      from (select bk.plate from public.bikes bk where bk.plate like '%' || v_plate || '%' limit 8) b;
    end if;
    return res;

  -- 用姓名找客戶（不回傳電話）
  elsif p_name = 'find_customer' then
    q := trim(coalesce(p_args->>'name', ''));
    if q = '' then raise exception '缺少姓名'; end if;
    return coalesce((select jsonb_agg(x) from (
      select c.name,
             (select jsonb_agg(jsonb_build_object('plate', b.plate, 'model', b.model))
              from public.bikes b where b.customer_id = c.id) as bikes,
             (select max(r.date) from public.service_records r
              join public.bikes b on b.id = r.bike_id where b.customer_id = c.id) as last_visit
      from public.customers c
      where c.name like '%' || q || '%'
      order by c.name limit 10) x), '[]'::jsonb);

  -- 某段期間的預約
  elsif p_name = 'list_appointments' then
    d1 := coalesce(nullif(p_args->>'from', '')::date, public.tw_now()::date);
    d2 := coalesce(nullif(p_args->>'to', '')::date, d1);
    return coalesce((select jsonb_agg(x) from (
      select date, to_char(time, 'HH24:MI') as time, plate, name, items, status, source
      from public.appointments
      where date between d1 and d2
      order by date, time nulls last limit 60) x), '[]'::jsonb);

  -- 工單看板：待修、維修中、今天完成
  elsif p_name = 'list_work_orders' then
    q := coalesce(nullif(p_args->>'status', ''), '未完成');
    return coalesce((select jsonb_agg(x) from (
      select r.date, b.plate, b.model, r.items, r.parts, r.total, r.status
      from public.service_records r join public.bikes b on b.id = r.bike_id
      where (q = '未完成' and r.status <> '已完成')
         or (q = '今天完成' and r.status = '已完成'
             and (r.completed_at at time zone 'Asia/Taipei')::date = public.tw_now()::date)
         or (q in ('待修', '維修中') and r.status = q)
      order by r.date, r.id limit 60) x), '[]'::jsonb);

  -- 庫存：可以用關鍵字找，或只看要叫貨的
  elsif p_name = 'stock_status' then
    q := trim(coalesce(p_args->>'keyword', ''));
    return jsonb_build_object(
      'parts', coalesce((select jsonb_agg(x) from (
        select p.name, p.spec, p.category, p.stock, p.unit, p.safety_stock, p.price,
               s.name as supplier,
               (p.stock <= p.safety_stock) as need_order
        from public.parts p left join public.suppliers s on s.id = p.supplier_id
        where p.active
          and (q = '' or p.name like '%' || q || '%' or p.spec like '%' || q || '%' or p.category like '%' || q || '%')
          and (coalesce((p_args->>'only_low')::boolean, false) = false or p.stock <= p.safety_stock)
        order by (p.stock <= p.safety_stock) desc, p.category, p.name limit 40) x), '[]'::jsonb),
      'pending_orders', coalesce((select jsonb_agg(x) from (
        select o.created_at::date as ordered_on, s.name as supplier,
               (select string_agg(p.name || coalesce(' ' || p.spec, '') || ' x' || i.qty, '、')
                from public.purchase_order_items i join public.parts p on p.id = i.part_id
                where i.order_id = o.id) as items
        from public.purchase_orders o left join public.suppliers s on s.id = o.supplier_id
        where o.status = '已叫貨' order by o.created_at) x), '[]'::jsonb)
    );

  else
    raise exception '不認得的查詢：%', p_name;
  end if;
end $$;

revoke execute on function public.assistant_tool(text, jsonb) from public, anon;
grant execute on function public.assistant_tool(text, jsonb) to authenticated;


-- ---------------------------------------------------------------------
-- 6. 檢查：跑完應該看到 6 張新表都是 true
-- ---------------------------------------------------------------------
select tablename, rowsecurity
from pg_tables
where schemaname = 'public'
  and tablename in ('booking_settings', 'booking_slots', 'booking_blocks',
                    'customer_accounts', 'bind_codes', 'bind_attempts');
