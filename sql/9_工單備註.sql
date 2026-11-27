-- =====================================================================
-- 9. 工單備註
--   工單多一個「備註」欄位。新增工單時可以只打備註，項目、金額都留空。
--   （項目留空時存成空字串，所以 items 的 not null 不用改）
-- 可以重複執行。
-- =====================================================================

alter table public.service_records add column if not exists note text;
comment on column public.service_records.note is '工單備註（店內自己看的）';

-- 檢查：應該看到 note
select column_name from information_schema.columns
where table_schema = 'public' and table_name = 'service_records' and column_name = 'note';
