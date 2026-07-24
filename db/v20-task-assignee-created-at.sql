-- ============================================================
-- v20 — タスク割り当ての新着表示
--   task_assignees に created_at を足し、「自分に割り当てられた新しいタスク」を
--   端末側が持つ最終確認時刻と比較して出せるようにする。
--   v16 でバッジ機構を撤去して以来、担当を割り振られた人はアプリを開いて
--   探すまで気づけなかった。tasks.created_at では「後から担当に足された」場合を拾えない。
--   既存行は紐づくタスクの created_at で埋める（全件が一斉に新着になるのを避ける）。
-- 何度流しても安全（idempotent）。
-- ============================================================

-- 1) まず null 許容で追加する。default now() を付けて追加すると、既存行が
--    「今の時刻」で埋まり、下のバックフィルと区別が付かなくなる。
alter table public.task_assignees add column if not exists created_at timestamptz;

-- 2) 既存行をタスクの作成時刻で埋める（null の行だけ＝再実行しても上書きしない）
update public.task_assignees ta
   set created_at = t.created_at
  from public.tasks t
 where t.id = ta.task_id
   and ta.created_at is null;

-- 3) 紐づくタスクが引けなかった行の保険
update public.task_assignees set created_at = now() where created_at is null;

-- 4) 以降の行は挿入時刻を持つ
alter table public.task_assignees alter column created_at set default now();
alter table public.task_assignees alter column created_at set not null;

create index if not exists idx_ta_user_created
  on public.task_assignees(user_id, created_at desc);

-- 5) 自分の担当行は自分で読めるようにする。
--    旧 ta_select は can_see_project だけで、案件メンバーでないタスク担当者は
--    自分の担当行すら引けず、新着件数を数えられない。
--    広げるのは「自分の行」だけで、他人の担当関係は従来どおり案件の可視範囲に従う。
drop policy if exists ta_select on public.task_assignees;
create policy ta_select on public.task_assignees for select to authenticated
  using (public.can_see_project(public.task_project(task_id)) or user_id = auth.uid());
