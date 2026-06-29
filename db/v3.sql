-- ============================================================
-- マイグレーション v3 — 発注（内注/外注）。経費とは別の依頼ledger。
-- モデルA: 費用は発注元の案件に1回計上。内注先ユーザーにも表示。
-- 何度流しても安全。
-- ============================================================
do $$ begin create type order_kind as enum ('内注','外注'); exception when duplicate_object then null; end $$;
do $$ begin create type order_status as enum ('依頼中','進行','完了','取消'); exception when duplicate_object then null; end $$;

create table if not exists public.orders (
  id         uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,  -- 発注元の案件
  task_id    uuid references public.tasks(id) on delete set null,             -- 任意：関連タスク
  kind       order_kind not null,
  vendor_id  uuid references public.vendors(id),                              -- 外注先（外注時）
  to_user_id uuid references public.profiles(id),                             -- 内注先ユーザー（内注時）
  from_user  uuid references public.profiles(id) default auth.uid(),          -- 発注元（依頼した人）
  title      text not null,
  amount     integer not null default 0 check (amount >= 0),
  note       text,
  status     order_status not null default '依頼中',
  created_at timestamptz not null default now()
);
create index if not exists idx_orders_project on public.orders(project_id);
create index if not exists idx_orders_touser  on public.orders(to_user_id);

alter table public.orders enable row level security;
-- 閲覧: その案件を見られる人 or 内注を受けた本人
drop policy if exists orders_select on public.orders;
create policy orders_select on public.orders for select to authenticated
  using (public.can_see_project(project_id) or to_user_id = auth.uid());
-- 作成: その案件を見られる人（発注元は本人）
drop policy if exists orders_insert on public.orders;
create policy orders_insert on public.orders for insert to authenticated
  with check (from_user = auth.uid() and public.can_see_project(project_id));
-- 更新/削除: 発注元 or 内注先 or 管理者
drop policy if exists orders_update on public.orders;
create policy orders_update on public.orders for update to authenticated
  using (from_user = auth.uid() or to_user_id = auth.uid() or public.is_manager());
drop policy if exists orders_delete on public.orders;
create policy orders_delete on public.orders for delete to authenticated
  using (from_user = auth.uid() or public.is_manager());

-- 監査ログにも乗せる
drop trigger if exists trg_audit_orders on public.orders;
create trigger trg_audit_orders after insert or update or delete on public.orders
  for each row execute function public.log_change();

-- log_change が orders の project_id を拾えるように差し替え
create or replace function public.log_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare rid uuid; pid uuid; act text := tg_op; sm text;
begin
  if tg_op = 'DELETE' then rid := (row_to_json(old)->>'id')::uuid;
  else rid := (row_to_json(new)->>'id')::uuid; end if;
  if tg_table_name = 'projects' then pid := rid;
  elsif tg_table_name in ('expenses','tasks','orders') then
    pid := coalesce((row_to_json(new)->>'project_id'), (row_to_json(old)->>'project_id'))::uuid;
  end if;
  sm := tg_table_name || ' ' || tg_op;
  insert into public.audit_log(table_name,row_id,action,project_id,summary,diff)
  values (tg_table_name, rid, act, pid, sm,
    jsonb_build_object('old', to_jsonb(old), 'new', to_jsonb(new)));
  return coalesce(new, old);
end $$;

-- ============================================================
-- project_costs 再定義: 原価 = 経費 + 発注（内注/外注とも発注元案件に計上）
--   サブクエリ集計で行の二重カウントを防ぐ。
-- ============================================================
drop view if exists public.project_costs;
create view public.project_costs as
select
  p.id,
  p.name,
  p.amount                                            as revenue,
  (coalesce(e.cost,0) + coalesce(o.cost,0))           as cost,
  (coalesce(e.out,0)  + coalesce(o.out,0))            as outsource,
  (p.amount - (coalesce(e.cost,0)+coalesce(o.cost,0))) as profit,
  case when p.amount > 0
    then round((p.amount - (coalesce(e.cost,0)+coalesce(o.cost,0)))::numeric / p.amount * 100, 1)
    else 0 end                                        as profit_rate
from public.projects p
left join (
  select project_id, sum(amount) as cost,
         sum(amount) filter (where kind='外注') as out
  from public.expenses group by project_id
) e on e.project_id = p.id
left join (
  select project_id, sum(amount) as cost,
         sum(amount) filter (where kind='外注') as out
  from public.orders group by project_id
) o on o.project_id = p.id;
