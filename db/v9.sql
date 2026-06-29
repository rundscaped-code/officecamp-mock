-- v9: tasks ↔ task_assignees のRLS相互再帰を解消
-- ポリシー内のテーブル参照を SECURITY DEFINER ヘルパに置換し、RLSの再評価ループを断つ。
create or replace function public.is_task_assignee(tid uuid) returns boolean
  language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.task_assignees where task_id=tid and user_id=auth.uid()); $$;
create or replace function public.task_project(tid uuid) returns uuid
  language sql stable security definer set search_path=public as $$
  select project_id from public.tasks where id=tid; $$;
create or replace function public.task_leader(tid uuid) returns uuid
  language sql stable security definer set search_path=public as $$
  select leader_id from public.tasks where id=tid; $$;
create or replace function public.project_owner(pid uuid) returns uuid
  language sql stable security definer set search_path=public as $$
  select owner_id from public.projects where id=pid; $$;

-- tasks: 担当者の更新可（task_assignees をヘルパ経由で参照→再帰しない）
drop policy if exists tasks_update_assignee on public.tasks;
create policy tasks_update_assignee on public.tasks for update to authenticated
  using (public.is_task_assignee(id)) with check (public.is_task_assignee(id));

-- task_assignees: tasks/projects をヘルパ経由で参照
drop policy if exists ta_select on public.task_assignees;
create policy ta_select on public.task_assignees for select to authenticated
  using (public.can_see_project(public.task_project(task_id)));
drop policy if exists ta_cud on public.task_assignees;
create policy ta_cud on public.task_assignees for all to authenticated
  using (public.is_manager() or public.task_leader(task_id)=auth.uid()
         or public.project_owner(public.task_project(task_id))=auth.uid())
  with check (public.is_manager() or public.task_leader(task_id)=auth.uid()
         or public.project_owner(public.task_project(task_id))=auth.uid());
