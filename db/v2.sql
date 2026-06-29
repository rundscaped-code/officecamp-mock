-- ============================================================
-- オフィスキャンプ 案件管理アプリ — マイグレーション v2
-- 追加: 外注 / タスク(ガント) / 案件メンバー(可視範囲) / 変更履歴(audit)
-- Supabase SQL Editor に貼って Run。何度流しても安全(idempotent)。
-- ============================================================

-- ---- enum ----
do $$ begin
  create type cost_kind   as enum ('経費','外注');
exception when duplicate_object then null; end $$;
do $$ begin
  create type vendor_kind as enum ('外部','社内部門');
exception when duplicate_object then null; end $$;
do $$ begin
  create type task_status as enum ('未着手','進行','完了','保留');
exception when duplicate_object then null; end $$;

-- ============================================================
-- 1. vendors（外注先マスタ）— 外部業者も社内部門も「外注先」として並ぶ
-- ============================================================
create table if not exists public.vendors (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  kind       vendor_kind not null default '外部',
  created_at timestamptz not null default now()
);
alter table public.vendors enable row level security;
drop policy if exists vendors_select on public.vendors;
create policy vendors_select on public.vendors for select to authenticated using (true);
drop policy if exists vendors_cud on public.vendors;
create policy vendors_cud on public.vendors for all to authenticated
  using (public.is_manager()) with check (public.is_manager());

-- ---- expenses に 外注種別 / 外注先 を追加 ----
alter table public.expenses add column if not exists kind      cost_kind not null default '経費';
alter table public.expenses add column if not exists vendor_id uuid references public.vendors(id);

-- ============================================================
-- 2. project_members（案件メンバー）— ここに居る人だけ案件を見れる
--    リーダーがアサイン→自動でメンバー追加(下のトリガ)
-- ============================================================
create table if not exists public.project_members (
  project_id uuid not null references public.projects(id) on delete cascade,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  added_by   uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now(),
  primary key (project_id, user_id)
);
create index if not exists idx_pm_user on public.project_members(user_id);

-- 自分がそのプロジェクトのメンバーか（RLS用ヘルパ・再帰回避のため security definer）
create or replace function public.is_member(pid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.project_members
    where project_id = pid and user_id = auth.uid()
  ) or exists (
    select 1 from public.projects
    where id = pid and owner_id = auth.uid()
  );
$$;

-- 案件を見れる人か（メンバー or 所有者 or 経理/管理者）
create or replace function public.can_see_project(pid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_manager() or public.is_member(pid);
$$;

-- ============================================================
-- 3. tasks（タスク＝ガント）
-- ============================================================
create table if not exists public.tasks (
  id         uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  title      text not null,
  start_date date,
  end_date   date,
  status     task_status not null default '未着手',
  progress   int not null default 0 check (progress between 0 and 100),
  leader_id  uuid references public.profiles(id),     -- 進める人
  created_by uuid references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_tasks_project on public.tasks(project_id);

create table if not exists public.task_assignees (
  task_id uuid not null references public.tasks(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  primary key (task_id, user_id)
);

-- アサインしたら、その人を案件メンバーに自動追加（→案件が見える・経費を足せる）
create or replace function public.on_assign_add_member()
returns trigger language plpgsql security definer set search_path = public as $$
declare pid uuid;
begin
  select project_id into pid from public.tasks where id = new.task_id;
  insert into public.project_members(project_id, user_id)
  values (pid, new.user_id) on conflict do nothing;
  return new;
end $$;
drop trigger if exists trg_assign_member on public.task_assignees;
create trigger trg_assign_member after insert on public.task_assignees
  for each row execute function public.on_assign_add_member();

-- ============================================================
-- 4. audit_log（変更履歴／通知の元）— 誰が・いつ・何を変えたか
-- ============================================================
create table if not exists public.audit_log (
  id         bigint generated always as identity primary key,
  table_name text not null,
  row_id     uuid,
  action     text not null,                 -- INSERT / UPDATE / DELETE
  actor_id   uuid default auth.uid(),
  project_id uuid,                           -- 案件単位でフィードを引けるように
  summary    text,
  diff       jsonb,
  created_at timestamptz not null default now()
);
create index if not exists idx_audit_project on public.audit_log(project_id, created_at desc);
alter table public.audit_log enable row level security;
drop policy if exists audit_select on public.audit_log;
create policy audit_select on public.audit_log for select to authenticated
  using (public.is_manager() or (project_id is not null and public.is_member(project_id)));

create or replace function public.log_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  rid uuid; pid uuid; act text := tg_op; sm text;
begin
  if tg_op = 'DELETE' then
    rid := (row_to_json(old)->>'id')::uuid;
  else
    rid := (row_to_json(new)->>'id')::uuid;
  end if;
  -- project_id を拾う（テーブルごと）
  if tg_table_name = 'projects' then pid := rid;
  elsif tg_table_name in ('expenses','tasks') then
    pid := coalesce((row_to_json(new)->>'project_id'), (row_to_json(old)->>'project_id'))::uuid;
  end if;
  sm := tg_table_name || ' ' || tg_op;
  insert into public.audit_log(table_name,row_id,action,project_id,summary,diff)
  values (tg_table_name, rid, act, pid, sm,
    jsonb_build_object('old', to_jsonb(old), 'new', to_jsonb(new)));
  return coalesce(new, old);
end $$;

drop trigger if exists trg_audit_projects on public.projects;
create trigger trg_audit_projects after insert or update or delete on public.projects
  for each row execute function public.log_change();
drop trigger if exists trg_audit_expenses on public.expenses;
create trigger trg_audit_expenses after insert or update or delete on public.expenses
  for each row execute function public.log_change();
drop trigger if exists trg_audit_tasks on public.tasks;
create trigger trg_audit_tasks after insert or update or delete on public.tasks
  for each row execute function public.log_change();

-- ============================================================
-- 5. RLS 改定 — 「メンバー/所有者/経理・管理者だけ案件を見れる」へ
--    （これまでの "全員閲覧" から締める）
-- ============================================================
-- projects：閲覧はメンバー等のみ。作成は誰でも（作った人が owner=自動メンバー）
drop policy if exists projects_select on public.projects;
create policy projects_select on public.projects for select to authenticated
  using (public.can_see_project(id));

-- expenses：閲覧は案件を見れる人のみ。追加は「メンバーで本人」
drop policy if exists expenses_select on public.expenses;
create policy expenses_select on public.expenses for select to authenticated
  using (public.can_see_project(project_id));
drop policy if exists expenses_insert on public.expenses;
create policy expenses_insert on public.expenses for insert to authenticated
  with check (user_id = auth.uid() and public.can_see_project(project_id));

-- project_members：自分が見れる案件のメンバー表は見える。追加/削除は所有者・リーダー・管理者
drop policy if exists pm_select on public.project_members;
create policy pm_select on public.project_members for select to authenticated
  using (public.can_see_project(project_id));
drop policy if exists pm_cud on public.project_members;
create policy pm_cud on public.project_members for all to authenticated
  using (public.is_manager() or exists (
           select 1 from public.projects p where p.id = project_id and p.owner_id = auth.uid()))
  with check (public.is_manager() or exists (
           select 1 from public.projects p where p.id = project_id and p.owner_id = auth.uid()));

-- tasks：閲覧は案件を見れる人。作成/更新/削除は所有者・リーダー・管理者
alter table public.tasks enable row level security;
drop policy if exists tasks_select on public.tasks;
create policy tasks_select on public.tasks for select to authenticated
  using (public.can_see_project(project_id));
drop policy if exists tasks_cud on public.tasks;
create policy tasks_cud on public.tasks for all to authenticated
  using (public.is_manager() or leader_id = auth.uid()
         or exists (select 1 from public.projects p where p.id = project_id and p.owner_id = auth.uid()))
  with check (public.is_manager() or leader_id = auth.uid()
         or exists (select 1 from public.projects p where p.id = project_id and p.owner_id = auth.uid()));

-- task_assignees：閲覧は案件メンバー、アサイン操作は所有者・リーダー・管理者
alter table public.task_assignees enable row level security;
drop policy if exists ta_select on public.task_assignees;
create policy ta_select on public.task_assignees for select to authenticated
  using (exists (select 1 from public.tasks t where t.id = task_id and public.can_see_project(t.project_id)));
drop policy if exists ta_cud on public.task_assignees;
create policy ta_cud on public.task_assignees for all to authenticated
  using (exists (select 1 from public.tasks t
           where t.id = task_id and (public.is_manager() or t.leader_id = auth.uid()
             or exists (select 1 from public.projects p where p.id = t.project_id and p.owner_id = auth.uid()))))
  with check (exists (select 1 from public.tasks t
           where t.id = task_id and (public.is_manager() or t.leader_id = auth.uid()
             or exists (select 1 from public.projects p where p.id = t.project_id and p.owner_id = auth.uid()))));

-- ============================================================
-- 6. 集計ビュー更新 — 外注計を追加
-- ============================================================
drop view if exists public.project_costs;
create view public.project_costs as
select
  p.id,
  p.name,
  p.amount                              as revenue,
  coalesce(sum(e.amount), 0)            as cost,
  coalesce(sum(e.amount) filter (where e.kind = '外注'), 0) as outsource,
  p.amount - coalesce(sum(e.amount), 0) as profit,
  case when p.amount > 0
       then round((p.amount - coalesce(sum(e.amount),0))::numeric / p.amount * 100, 1)
       else 0 end                       as profit_rate
from public.projects p
left join public.expenses e on e.project_id = p.id
group by p.id;

-- ============================================================
-- 7. 既存案件の所有者を全員メンバーに（移行：今ある案件を見えなくしないため）
--    owner_id が入っている案件は owner を member 化。
-- ============================================================
insert into public.project_members(project_id, user_id)
select id, owner_id from public.projects where owner_id is not null
on conflict do nothing;

-- 完了
