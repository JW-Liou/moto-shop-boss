-- =====================================================================
-- 老闆版：全新資料庫一次建好
-- 在「新的」Supabase 專案的 SQL Editor 執行一次就好
-- 包含：6 張資料表、資料檢查規則、索引、員工門禁（RLS）、操作紀錄與垃圾桶、通知欄位
-- 執行前：先到 Authentication → Users 建好店家帳號（見最下面第 6 步）
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. 資料表
-- ---------------------------------------------------------------------

-- 客戶
create table if not exists public.customers (
  id           bigint generated always as identity primary key,
  name         text not null,
  phone        text,
  note         text,
  created_at   timestamptz not null default now(),
  -- 只留數字的電話，0912-345-678 和 0912345678 會被當成同一支（資料庫自動算）
  phone_digits text generated always as (regexp_replace(coalesce(phone, ''), '\D', '', 'g')) stored
);

-- 車輛（一位客戶可以有很多台車）
create table if not exists public.bikes (
  id          bigint generated always as identity primary key,
  customer_id bigint references public.customers(id) on delete cascade,
  plate       text not null unique,
  model       text,
  year        int check (year between 1950 and 2100),
  mileage     int check (mileage >= 0),
  created_at  timestamptz not null default now()
);

-- 工單（一台車可以有很多張工單）
create table if not exists public.service_records (
  id              bigint generated always as identity primary key,
  bike_id         bigint not null references public.bikes(id) on delete cascade,
  date            date default current_date,
  mileage         int check (mileage >= 0),
  items           text not null,
  parts           text,
  total           int not null default 0 check (total >= 0),
  status          text not null default '待修' check (status in ('待修', '維修中', '已完成')),
  next_service_km int,
  created_at      timestamptz not null default now(),
  completed_at    timestamptz,     -- 改成「已完成」的時間，營收算在這一天
  notified_at     timestamptz      -- 通知車主來取車的時間
);

-- 預約（用車牌文字對應車輛，還沒建檔的新客人也能預約）
create table if not exists public.appointments (
  id         bigint generated always as identity primary key,
  date       date not null,
  time       time,
  plate      text,
  name       text,
  phone      text,
  items      text,
  status     text not null default '預約中' check (status in ('預約中', '已到店', '取消')),
  source     text not null default '店內',
  created_at timestamptz not null default now()
);

-- 店內便條
create table if not exists public.notes (
  id         bigint generated always as identity primary key,
  content    text not null,
  done       boolean not null default false,
  author     text,
  created_at timestamptz not null default now()
);

-- 員工名單：在這張表上的帳號才能使用系統
create table if not exists public.staff (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  email      text,
  role       text not null default '員工',
  created_at timestamptz not null default now()
);


-- ---------------------------------------------------------------------
-- 2. 索引：讓查詢變快
-- ---------------------------------------------------------------------
create index if not exists customers_phone_digits_idx   on public.customers (phone_digits);
create index if not exists bikes_customer_id_idx         on public.bikes (customer_id);
create index if not exists service_records_bike_id_idx   on public.service_records (bike_id);
create index if not exists service_records_date_idx      on public.service_records (date);
create index if not exists service_records_completed_idx on public.service_records (completed_at);
create index if not exists appointments_date_idx         on public.appointments (date);


-- ---------------------------------------------------------------------
-- 3. 員工門禁（RLS）：只有員工名單上的登入帳號能讀寫
-- ---------------------------------------------------------------------
create or replace function public.is_staff()
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select exists (select 1 from public.staff where user_id = auth.uid());
$$;

alter table public.customers       enable row level security;
alter table public.bikes           enable row level security;
alter table public.service_records enable row level security;
alter table public.appointments    enable row level security;
alter table public.notes           enable row level security;
alter table public.staff           enable row level security;

drop policy if exists "staff only" on public.customers;
create policy "staff only" on public.customers for all to authenticated
  using ((select public.is_staff())) with check ((select public.is_staff()));

drop policy if exists "staff only" on public.bikes;
create policy "staff only" on public.bikes for all to authenticated
  using ((select public.is_staff())) with check ((select public.is_staff()));

drop policy if exists "staff only" on public.service_records;
create policy "staff only" on public.service_records for all to authenticated
  using ((select public.is_staff())) with check ((select public.is_staff()));

drop policy if exists "staff only" on public.appointments;
create policy "staff only" on public.appointments for all to authenticated
  using ((select public.is_staff())) with check ((select public.is_staff()));

drop policy if exists "staff only" on public.notes;
create policy "staff only" on public.notes for all to authenticated
  using ((select public.is_staff())) with check ((select public.is_staff()));

-- 員工名單：每個人只看得到自己那一列（不能從網頁新增或修改員工）
drop policy if exists "read own row" on public.staff;
create policy "read own row" on public.staff for select to authenticated
  using (user_id = (select auth.uid()));


-- ---------------------------------------------------------------------
-- 4. 操作紀錄與垃圾桶
-- ---------------------------------------------------------------------
create table if not exists public.activity_log (
  id          bigint generated always as identity primary key,
  at          timestamptz not null default now(),
  table_name  text not null,
  action      text not null,       -- INSERT 新增／UPDATE 修改／DELETE 刪除／RESTORE 救回
  row_id      bigint,
  old_data    jsonb,
  new_data    jsonb,
  device      text,
  restored_at timestamptz
);
create index if not exists activity_log_at_idx on public.activity_log (at desc);

alter table public.activity_log enable row level security;
drop policy if exists "staff read log" on public.activity_log;
create policy "staff read log" on public.activity_log
  for select to authenticated using ((select public.is_staff()));
drop policy if exists "staff mark restored" on public.activity_log;
create policy "staff mark restored" on public.activity_log
  for update to authenticated using ((select public.is_staff())) with check ((select public.is_staff()));

create or replace function public.log_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  ua  text := coalesce(nullif(current_setting('request.headers', true), '')::json ->> 'user-agent', '');
  dev text;
begin
  if tg_op = 'UPDATE' and to_jsonb(old) = to_jsonb(new) then
    return new;
  end if;
  dev := case
    when ua = ''           then '資料庫後台'
    when ua ~* 'iphone'    then 'iPhone'
    when ua ~* 'ipad'      then 'iPad'
    when ua ~* 'android'   then 'Android 手機'
    when ua ~* 'windows'   then 'Windows 電腦'
    when ua ~* 'macintosh' then 'Mac 電腦'
    else '其他裝置'
  end;
  insert into public.activity_log (table_name, action, row_id, old_data, new_data, device)
  values (tg_table_name, tg_op,
          case when tg_op = 'DELETE' then old.id else new.id end,
          case when tg_op <> 'INSERT' then to_jsonb(old) end,
          case when tg_op <> 'DELETE' then to_jsonb(new) end,
          dev);
  if random() < 0.01 then
    delete from public.activity_log where at < now() - interval '180 days';
  end if;
  return coalesce(new, old);
end $$;
revoke execute on function public.log_change() from public, anon, authenticated;

drop trigger if exists log_changes on public.customers;
create trigger log_changes after insert or update or delete on public.customers
  for each row execute function public.log_change();
drop trigger if exists log_changes on public.bikes;
create trigger log_changes after insert or update or delete on public.bikes
  for each row execute function public.log_change();
drop trigger if exists log_changes on public.service_records;
create trigger log_changes after insert or update or delete on public.service_records
  for each row execute function public.log_change();
drop trigger if exists log_changes on public.appointments;
create trigger log_changes after insert or update or delete on public.appointments
  for each row execute function public.log_change();

create or replace function public.restore_deleted(log_id bigint)
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  l    public.activity_log%rowtype;
  cols text;
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
  if l.table_name not in ('customers', 'bikes', 'service_records', 'appointments') then
    raise exception '這種資料不能救回';
  end if;
  select string_agg(quote_ident(column_name), ', ' order by ordinal_position) into cols
  from information_schema.columns
  where table_schema = 'public' and table_name = l.table_name and is_generated = 'NEVER';
  begin
    execute format(
      'insert into public.%I (%s) overriding system value select %s from jsonb_populate_record(null::public.%I, $1)',
      l.table_name, cols, cols, l.table_name
    ) using l.old_data;
  exception
    when foreign_key_violation then
      raise exception '它所屬的車輛或客戶也被刪掉了，請先救回那一筆';
    when unique_violation then
      raise exception '已經有一樣的資料（例如同一個車牌）存在，不能救回';
  end;
  update public.activity_log set restored_at = now() where id = log_id;
  update public.activity_log set action = 'RESTORE'
  where id = (select max(id) from public.activity_log
              where table_name = l.table_name and row_id = l.row_id and action = 'INSERT');
  return 'ok';
end $$;
revoke execute on function public.restore_deleted(bigint) from public, anon;
grant execute on function public.restore_deleted(bigint) to authenticated;


-- ---------------------------------------------------------------------
-- 4-1. 開放「登入的人」透過網頁存取這些表（真正能不能讀寫，還是由上面的 RLS 決定）
--      新專案沒勾「Grant API access to new tables automatically」也能用
-- ---------------------------------------------------------------------
grant usage on schema public to authenticated;
grant select, insert, update, delete on public.customers, public.bikes, public.service_records,
  public.appointments, public.notes to authenticated;
grant select on public.staff to authenticated;
grant select, update on public.activity_log to authenticated;
grant execute on function public.is_staff() to authenticated;


-- ---------------------------------------------------------------------
-- 5. 把店家帳號加進員工名單
--    把下面的 email 換成你在 Authentication → Users 建立的店家帳號
-- ---------------------------------------------------------------------
insert into public.staff (user_id, email, role)
select id, email, '老闆'
from auth.users
where email = '改成店家的email@example.com'
on conflict (user_id) do nothing;


-- ---------------------------------------------------------------------
-- 6. 檢查結果：應該看到 7 張表都是「已開啟」，員工名單至少 1 人
-- ---------------------------------------------------------------------
select c.relname as 資料表,
       case when c.relrowsecurity then '已開啟' else '沒開！' end as 員工門禁
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r'
order by 1;

select count(*) as 員工名單人數 from public.staff;
