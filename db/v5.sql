-- ============================================================
-- マイグレーション v5 — 担当者がタスク状態を編集可 / 発注→タスク自動生成
-- client(受注元)列は既存のため流用（マイグレーション不要）。
-- 何度流しても安全。
-- ============================================================

-- 1) 担当者（task_assignees）も自分のタスクを更新できる
drop policy if exists tasks_update_assignee on public.tasks;
create policy tasks_update_assignee on public.tasks for update to authenticated
  using (exists (select 1 from public.task_assignees ta
                 where ta.task_id = tasks.id and ta.user_id = auth.uid()))
  with check (exists (select 1 from public.task_assignees ta
                 where ta.task_id = tasks.id and ta.user_id = auth.uid()));

-- 2) 発注が入ったら、その案件にタスクを自動生成
create or replace function public.order_to_task()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.tasks(project_id, title, status, created_by)
  values (new.project_id, '【'||new.kind||'】'||new.title, '未着手', new.from_user);
  return new;
end $$;
drop trigger if exists trg_order_task on public.orders;
create trigger trg_order_task after insert on public.orders
  for each row execute function public.order_to_task();
