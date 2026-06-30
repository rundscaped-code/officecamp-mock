-- ============================================================
-- v14 — 可視性の二段階化 ＋ 発注で受注側に案件を自動生成
--   ④ タスク担当 = 自分のタスク＋案件名のみ / 案件メンバー = 案件の全タスク
--   ③ 発注: 発注元 = 発注管理タスク（元の案件に追加） / 受注側(内注先) = 案件として追加
-- 何度流しても安全（idempotent）。
-- ============================================================

-- 1) 「タスク担当→案件メンバー」自動昇格をやめる（担当とメンバーを分離）
--    今後はメンバー追加を明示操作に限る（案件詳細のメンバー欄）。
drop trigger if exists trg_assign_member on public.task_assignees;

-- 2) ヘルパ: 現ユーザーがその案件のいずれかのタスクの担当か（security definer で再帰回避）
create or replace function public.is_project_task_assignee(pid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(
    select 1
    from public.task_assignees ta
    join public.tasks t on t.id = ta.task_id
    where t.project_id = pid and ta.user_id = auth.uid());
$$;

-- 3) tasks 閲覧: 案件を見れる人(=メンバー/所有者/管理者) または そのタスクの担当本人
drop policy if exists tasks_select on public.tasks;
create policy tasks_select on public.tasks for select to authenticated
  using (public.can_see_project(project_id) or public.is_task_assignee(id));

-- 4) projects 閲覧: メンバー等 または その案件のタスク担当（案件名を見せるため）
drop policy if exists projects_select on public.projects;
create policy projects_select on public.projects for select to authenticated
  using (public.can_see_project(id) or public.is_project_task_assignee(id));

-- 5) 集計ビュー（受注額/原価/粗利）はメンバー/管理者だけに保つ。
--    projects_select をタスク担当へ広げたので、ビュー側で明示的に締め直す
--    （担当者には案件名は見せるが金額は見せない）。
drop view if exists public.project_costs;
create view public.project_costs with (security_invoker = true) as
select
  p.id, p.name, p.code, p.parent_id,
  p.amount                                             as revenue,
  (coalesce(e.cost,0) + coalesce(o.cost,0))            as cost,
  (coalesce(e.out,0)  + coalesce(o.out,0))             as outsource,
  (p.amount - (coalesce(e.cost,0)+coalesce(o.cost,0))) as profit,
  case when p.amount > 0
    then round((p.amount - (coalesce(e.cost,0)+coalesce(o.cost,0)))::numeric / p.amount * 100, 1)
    else 0 end                                         as profit_rate
from public.projects p
left join (select project_id, sum(amount) as cost, sum(amount) filter (where kind='外注') as out
           from public.expenses group by project_id) e on e.project_id = p.id
left join (select project_id, sum(amount) as cost, sum(amount) filter (where kind='外注') as out
           from public.orders   group by project_id) o on o.project_id = p.id
where public.can_see_project(p.id);

-- 6) 発注トリガを更新:
--    a. 発注元の元案件に「発注管理」タスクを追加（従来どおり、ラベルを発注管理に）
--    b. 内注先ユーザーがいれば、その人を所有者とする案件を新規作成（受注側＝案件）
create or replace function public.order_to_task()
returns trigger language plpgsql security definer set search_path = public as $$
declare newpid uuid;
begin
  -- a. 発注元: 発注管理タスク（元の案件にぶら下げる）
  insert into public.tasks(project_id, title, status, created_by)
  values (new.project_id, '【発注管理】'||new.title, '未着手', new.from_user);

  -- b. 受注側: 内注先ユーザーがいれば案件を自動生成（受注額=発注額・所有者=受注者）
  if new.to_user_id is not null then
    insert into public.projects(name, amount, owner_id, status, note)
    values (new.title, coalesce(new.amount,0), new.to_user_id, '進行',
            '発注より自動生成（発注元: '||coalesce((select code from public.projects where id=new.project_id),'')||'）')
    returning id into newpid;
    -- 受注者を案件メンバーにも入れて、自分の案件の全タスクを見られるように
    insert into public.project_members(project_id, user_id)
      values (newpid, new.to_user_id) on conflict do nothing;
  end if;
  return new;
end $$;
-- トリガ本体は v5 で作成済（trg_order_task）。関数差し替えのみで反映される。
