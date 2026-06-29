-- v8: サブタスク（親タスク参照）
alter table public.tasks add column if not exists parent_task_id uuid references public.tasks(id) on delete cascade;
create index if not exists idx_tasks_parent on public.tasks(parent_task_id);
