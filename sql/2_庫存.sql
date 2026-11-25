-- =====================================================================
-- 老闆版：庫存管理
-- 在老闆版的 Supabase 執行一次（要先跑過「sql/1_全新資料庫.sql」）
-- 可以重複執行，不會出錯
--
-- 5 張表：
--   suppliers            廠商（跟誰叫貨、電話、LINE）
--   parts                零件品項（現在幾個、低於多少要叫貨、售價）
--   purchase_orders      叫貨單（已叫貨 → 已到貨）
--   purchase_order_items 叫貨單上的品項和數量
--   stock_moves          庫存異動（進貨＋、工單用掉－、盤點調整），庫存數量由它自動算
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. 資料表
-- ---------------------------------------------------------------------
create table if not exists public.suppliers (
  id         bigint generated always as identity primary key,
  name       text not null,
  phone      text,
  line_id    text,
  note       text,
  created_at timestamptz not null default now()
);

create table if not exists public.parts (
  id           bigint generated always as identity primary key,
  name         text not null,                         -- 品名，例如：空濾
  spec         text,                                  -- 規格，例如：勁戰六代、10W-40 1L
  category     text not null default '其他',          -- 分類，例如：機油、輪胎
  unit         text not null default '個',            -- 單位：瓶、顆、條、組
  stock        int  not null default 0,               -- 現在的數量（由異動紀錄自動加減，不要直接改）
  safety_stock int  not null default 0 check (safety_stock >= 0),  -- 低於或等於這個數字就要叫貨
  price        int  check (price >= 0),               -- 售價（開工單選零件時自動帶入金額）
  supplier_id  bigint references public.suppliers(id) on delete set null,
  note         text,
  active       boolean not null default true,         -- 不再進貨的品項可以停用
  created_at   timestamptz not null default now()
);
create unique index if not exists parts_name_spec_key on public.parts (name, coalesce(spec, ''));

create table if not exists public.purchase_orders (
  id          bigint generated always as identity primary key,
  supplier_id bigint references public.suppliers(id) on delete set null,
  status      text not null default '已叫貨' check (status in ('已叫貨', '已到貨', '取消')),
  note        text,
  created_at  timestamptz not null default now(),
  received_at timestamptz
);

create table if not exists public.purchase_order_items (
  id       bigint generated always as identity primary key,
  order_id bigint not null references public.purchase_orders(id) on delete cascade,
  part_id  bigint not null references public.parts(id) on delete cascade,
  qty      int not null check (qty > 0)
);

create table if not exists public.stock_moves (
  id         bigint generated always as identity primary key,
  part_id    bigint not null references public.parts(id) on delete cascade,
  change     int not null check (change <> 0),                 -- ＋進貨、－用掉
  reason     text not null check (reason in ('期初', '進貨', '工單使用', '盤點調整', '退貨', '其他')),
  record_id  bigint references public.service_records(id) on delete cascade,  -- 工單刪掉，用掉的零件自動加回來
  order_id   bigint references public.purchase_orders(id) on delete set null,
  note       text,
  created_at timestamptz not null default now()
);

create index if not exists parts_supplier_idx      on public.parts (supplier_id);
create index if not exists poi_order_idx           on public.purchase_order_items (order_id);
create index if not exists stock_moves_part_idx    on public.stock_moves (part_id, created_at desc);
create index if not exists stock_moves_record_idx  on public.stock_moves (record_id);
create index if not exists stock_moves_created_idx on public.stock_moves (created_at desc);


-- ---------------------------------------------------------------------
-- 2. 庫存數量自動計算：新增一筆異動就加減，刪掉異動就加減回來
-- ---------------------------------------------------------------------
create or replace function public.apply_stock_move()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    update public.parts set stock = stock + new.change where id = new.part_id;
    return new;
  else
    update public.parts set stock = stock - old.change where id = old.part_id;
    return old;
  end if;
end $$;

drop trigger if exists stock_moves_apply on public.stock_moves;
create trigger stock_moves_apply after insert or delete on public.stock_moves
  for each row execute function public.apply_stock_move();


-- ---------------------------------------------------------------------
-- 3. 到貨入庫：叫貨單上的每個品項一次加進庫存（全部成功或全部不做）
-- ---------------------------------------------------------------------
create or replace function public.receive_order(p_order_id bigint)
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  o public.purchase_orders%rowtype;
begin
  if not public.is_staff() then
    raise exception '沒有權限';
  end if;
  select * into o from public.purchase_orders where id = p_order_id for update;
  if not found then
    raise exception '找不到這張叫貨單';
  end if;
  if o.status <> '已叫貨' then
    raise exception '這張叫貨單是「%」，不能再入庫', o.status;
  end if;

  insert into public.stock_moves (part_id, change, reason, order_id, note)
  select i.part_id, i.qty, '進貨', o.id, '叫貨單 #' || o.id || ' 到貨'
  from public.purchase_order_items i
  where i.order_id = o.id;

  update public.purchase_orders set status = '已到貨', received_at = now() where id = o.id;
  return 'ok';
end $$;
revoke execute on function public.receive_order(bigint) from public, anon;
grant execute on function public.receive_order(bigint) to authenticated;


-- ---------------------------------------------------------------------
-- 4. 門禁：一樣只有員工能讀寫
-- ---------------------------------------------------------------------
alter table public.suppliers            enable row level security;
alter table public.parts                enable row level security;
alter table public.purchase_orders      enable row level security;
alter table public.purchase_order_items enable row level security;
alter table public.stock_moves          enable row level security;

drop policy if exists "staff only" on public.suppliers;
create policy "staff only" on public.suppliers for all to authenticated
  using ((select public.is_staff())) with check ((select public.is_staff()));
drop policy if exists "staff only" on public.parts;
create policy "staff only" on public.parts for all to authenticated
  using ((select public.is_staff())) with check ((select public.is_staff()));
drop policy if exists "staff only" on public.purchase_orders;
create policy "staff only" on public.purchase_orders for all to authenticated
  using ((select public.is_staff())) with check ((select public.is_staff()));
drop policy if exists "staff only" on public.purchase_order_items;
create policy "staff only" on public.purchase_order_items for all to authenticated
  using ((select public.is_staff())) with check ((select public.is_staff()));
drop policy if exists "staff only" on public.stock_moves;
create policy "staff only" on public.stock_moves for all to authenticated
  using ((select public.is_staff())) with check ((select public.is_staff()));

grant select, insert, update, delete on public.suppliers, public.parts, public.purchase_orders,
  public.purchase_order_items, public.stock_moves to authenticated;


-- ---------------------------------------------------------------------
-- 5. 操作紀錄：零件和廠商的新增、修改、刪除也記下來（刪錯可以救回）
--    stock_moves 本身就是紀錄，不用再記
-- ---------------------------------------------------------------------
drop trigger if exists log_changes on public.parts;
create trigger log_changes after insert or update or delete on public.parts
  for each row execute function public.log_change();
drop trigger if exists log_changes on public.suppliers;
create trigger log_changes after insert or update or delete on public.suppliers
  for each row execute function public.log_change();

-- 零件的「庫存數量」每次進出都會變，那些已經記在 stock_moves 了，操作紀錄就不重複記
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
  if tg_op = 'UPDATE' and tg_table_name = 'parts' and (to_jsonb(old) - 'stock') = (to_jsonb(new) - 'stock') then
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

-- 救回功能：多開放零件和廠商
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
-- 6. 檢查：應該看到 5 張新表都「已開啟」
-- ---------------------------------------------------------------------
select c.relname as 資料表,
       case when c.relrowsecurity then '已開啟' else '沒開！' end as 員工門禁
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname in ('suppliers', 'parts', 'purchase_orders', 'purchase_order_items', 'stock_moves')
order by 1;
