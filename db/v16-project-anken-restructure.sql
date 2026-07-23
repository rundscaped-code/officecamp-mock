-- ============================================================
-- v16 — プロジェクト−案件−タスク再編（spec/restructure-project-anken.md）
--   プロジェクト = projects の親行（parent_id IS NULL）
--   案件         = projects の子行（parent_id = プロジェクトid。担当 = leader_id の一人）
--   メンバー     = 子案件の leader_id 集合。project_members へトリガ自動同期（手動運用廃止）
--   経費         = 申請先 charge_to（self/member/client）と負担者 charged_user_id を追加
--   発注(orders) = テーブル・トリガ残置。UI から触らない。project_costs の原価にも算入しない
-- 何度流しても安全（idempotent）。
-- ============================================================

-- ============================================================
-- 1) expenses: 申請先（charge_to）と負担者（charged_user_id）
--    self=申請者本人の負担 / member=選択メンバーの負担 / client=先方請求（負担者なし）
-- ============================================================
alter table public.expenses
  add column if not exists charge_to text not null default 'self'
    check (charge_to in ('self','member','client'));
alter table public.expenses
  add column if not exists charged_user_id uuid references public.profiles(id);

-- 既存行のバックフィル: self は申請者本人の負担
update public.expenses
   set charged_user_id = user_id
 where charge_to = 'self' and charged_user_id is null;

-- ============================================================
-- 2) FK 付け替え: プロジェクト削除で配下（案件・タスク・経費）を丸ごと消す
--    expenses.project_id: on delete restrict → cascade
--    projects.parent_id : on delete set null → cascade
--    制約名は既定名（inline references で作られたもの）。drop→add で冪等。
-- ============================================================
alter table public.expenses drop constraint if exists expenses_project_id_fkey;
alter table public.expenses
  add constraint expenses_project_id_fkey
  foreign key (project_id) references public.projects(id) on delete cascade;

alter table public.projects drop constraint if exists projects_parent_id_fkey;
alter table public.projects
  add constraint projects_parent_id_fkey
  foreign key (parent_id) references public.projects(id) on delete cascade;

-- ============================================================
-- 3) can_see_project 差し替え（security definer 維持＝RLS 再帰回避）
--    見える = 経理/管理者
--           / 行の owner_id・leader_id が自分
--           / project_members に自分
--           / 親行（parent_id）の owner・leader・member に自分（親が見える人には子も見える）
--    「担当する子の親」は、子の leader が親の member にトリガ同期されるため member 経由で満たす。
-- ============================================================
create or replace function public.can_see_project(pid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_manager()
      or exists (
           select 1
           from public.projects p
           left join public.projects pp on pp.id = p.parent_id
           where p.id = pid
             and ( p.owner_id  = auth.uid() or p.leader_id  = auth.uid()
                or pp.owner_id = auth.uid() or pp.leader_id = auth.uid()
                or exists (select 1 from public.project_members m
                           where m.user_id = auth.uid()
                             and m.project_id in (p.id, pp.id))));
$$;

-- 指定行の owner/leader が自分か（projects の更新/削除ポリシーと
-- project_costs の子行フィルタで「親の owner・leader」を判定するヘルパ。再帰回避）
create or replace function public.is_project_owner_or_leader(pid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.projects
    where id = pid and (owner_id = auth.uid() or leader_id = auth.uid()));
$$;

-- ============================================================
-- 4) project_members 自動同期: メンバー = 子案件の leader_id 集合（非null）
--    projects の insert / update(leader_id, parent_id) / delete で、
--    影響する親（新旧両方）を全消し全入れで再計算する。手動追加/削除は廃止。
-- ============================================================
create or replace function public.sync_anken_members()
returns trigger language plpgsql security definer set search_path = public as $$
declare pids uuid[] := '{}'; pid uuid;
begin
  -- 影響する親 id を集める（UPDATE で親が付け替わった場合は新旧両方）。
  -- DELETE では new を参照しないよう tg_op で分岐。
  if tg_op in ('INSERT','UPDATE') and new.parent_id is not null then
    pids := array_append(pids, new.parent_id);
  end if;
  if tg_op in ('UPDATE','DELETE') and old.parent_id is not null then
    pids := array_append(pids, old.parent_id);
  end if;
  for pid in select distinct u from unnest(pids) u order by u loop
    -- 親行をロックして親単位で直列化（並行する担当替えで、全消し全入れが互いの
    -- 挿入行を見えないまま走り旧担当のメンバー行が残る競合の防止。order by は
    -- 複数親を同順で掴むデッドロック回避）。カスケード削除中は行が無い＝not found
    -- でスキップ（FK 違反回避を兼ねる）。
    perform 1 from public.projects where id = pid for update;
    continue when not found;
    delete from public.project_members where project_id = pid;
    insert into public.project_members(project_id, user_id)
    select distinct pid, c.leader_id
      from public.projects c
     where c.parent_id = pid and c.leader_id is not null
    on conflict do nothing;
  end loop;
  return coalesce(new, old);
end $$;

drop trigger if exists trg_sync_anken_members on public.projects;
create trigger trg_sync_anken_members
  after insert or update of leader_id, parent_id or delete on public.projects
  for each row execute function public.sync_anken_members();

-- 初期同期: 既存の手動メンバー行は破棄し、導出定義（子の leader_id 集合）で作り直す
--（spec: 手動運用は廃止・既存の手動行は消えてよい。現状は子案件が無いため実質は全消し）
delete from public.project_members;
insert into public.project_members(project_id, user_id)
select distinct c.parent_id, c.leader_id
  from public.projects c
 where c.parent_id is not null and c.leader_id is not null
on conflict do nothing;

-- ============================================================
-- 5) project_costs 再定義（security_invoker = true）
--    orders は cost に算入しない（旧定義からの意図的な変更）:
--      発注は「案件割り振り」に統合され、プロジェクトの発注計は anken_sum
--      （子案件 amount の合計）として別列で持つ。残置された旧 orders 行を
--      cost に足すと anken_sum と二重計上になるため外す。
--    行フィルタ: can_see_project(id) かつ
--      親行 = そのまま / 子行 = 経理・管理者 or 子の leader が自分 or 親の owner・leader が自分
--      （非担当メンバーに他人の案件金額を見せない）
-- ============================================================
drop view if exists public.project_costs;
create view public.project_costs with (security_invoker = true) as
with exp as (
  -- 行ごとの経費: cost = 非 client（自己負担・メンバー負担）/ client_billed = 先方請求
  select project_id,
         coalesce(sum(amount) filter (where charge_to <> 'client'), 0) as cost,
         coalesce(sum(amount) filter (where charge_to = 'client'), 0)  as client_billed
  from public.expenses
  group by project_id
),
kids as (
  -- 親ごとの子案件集計（件数・発注計・子の経費）
  select c.parent_id,
         count(*)                          as anken_count,
         coalesce(sum(c.amount), 0)        as anken_sum,
         coalesce(sum(e.cost), 0)          as kids_cost,
         coalesce(sum(e.client_billed), 0) as kids_client
  from public.projects c
  left join exp e on e.project_id = c.id
  where c.parent_id is not null
  group by c.parent_id
)
select s.*,
       case when s.revenue > 0
            then round(s.profit::numeric / s.revenue * 100, 1)
            else 0 end as profit_rate
from (
  select
    p.id, p.name, p.code, p.parent_id, p.leader_id, p.status, p.client,
    p.delivery_date, p.start_date,
    p.amount                     as revenue,
    coalesce(k.anken_count, 0)   as anken_count,
    coalesce(k.anken_sum, 0)     as anken_sum,
    coalesce(e.cost, 0)          as cost,
    coalesce(e.client_billed, 0) as client_billed,
    -- tree_* は親のみ意味を持つ（自行＋全子行）。子行は自行と同値
    coalesce(e.cost, 0)
      + case when p.parent_id is null then coalesce(k.kids_cost, 0) else 0 end   as tree_cost,
    coalesce(e.client_billed, 0)
      + case when p.parent_id is null then coalesce(k.kids_client, 0) else 0 end as tree_client,
    -- 粗利: 親 = 金額 − 発注計 / 子 = 金額 + クライアント請求 − 経費
    case when p.parent_id is null
         then p.amount - coalesce(k.anken_sum, 0)
         else p.amount + coalesce(e.client_billed, 0) - coalesce(e.cost, 0) end  as profit
  from public.projects p
  left join exp  e on e.project_id = p.id
  left join kids k on k.parent_id  = p.id
  where public.can_see_project(p.id)
    and ( p.parent_id is null
          or public.is_manager()
          or p.leader_id = auth.uid()
          or public.is_project_owner_or_leader(p.parent_id) )
) s;

-- ============================================================
-- 6) projects の更新/削除ポリシー:
--    本人（owner/leader）・親の owner/leader・経理/管理者。
--    insert / select は現状維持（select は can_see_project の新定義で自動的に変わる）。
-- ============================================================
drop policy if exists projects_update on public.projects;
create policy projects_update on public.projects for update to authenticated
  using (owner_id = auth.uid() or leader_id = auth.uid() or public.is_manager()
         or (parent_id is not null and public.is_project_owner_or_leader(parent_id)));
drop policy if exists projects_delete on public.projects;
create policy projects_delete on public.projects for delete to authenticated
  using (owner_id = auth.uid() or leader_id = auth.uid() or public.is_manager()
         or (parent_id is not null and public.is_project_owner_or_leader(parent_id)));

-- ============================================================
-- 7) project_task_labels を db 管理に固定
--    （本番には ad-hoc 版が存在＝db/ にファイル無し。ここで spec の定義に置き換える）
--    タスク担当者に案件のラベル（名前・コード・日付）だけ返す。金額・客先は含めない。
-- ============================================================
drop view if exists public.project_task_labels;
create view public.project_task_labels with (security_invoker = true) as
select id, name, code, status, start_date, end_date, delivery_date
from public.projects
where public.can_see_project(id) or public.is_project_task_assignee(id);

-- ============================================================
-- 8) log_change 差し替え: projects 行の audit_log.project_id を coalesce(parent_id, id) に
--    （案件＝子行の変更が親プロジェクトの変更履歴フィードに載る）。他テーブルは現状維持。
-- ============================================================
create or replace function public.log_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare rid uuid; pid uuid; act text := tg_op; sm text;
begin
  if tg_op = 'DELETE' then rid := (row_to_json(old)->>'id')::uuid;
  else rid := (row_to_json(new)->>'id')::uuid; end if;
  if tg_table_name = 'projects' then
    -- v16: 子行（案件）は親プロジェクトのフィードへ。親行は従来どおり自分自身。
    pid := coalesce(
      coalesce((row_to_json(new)->>'parent_id'), (row_to_json(old)->>'parent_id'))::uuid,
      rid);
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
-- 9) audit_log の閲覧を can_see_project 基準へ
--    旧ポリシーは is_member（owner/member のみ）で、リーダーが自プロジェクトの
--    変更履歴を見られない。新モデルの可視定義（リーダー・親子関係を含む）に揃える。
--    ただし projects 行（プロジェクト・案件の金額 diff を含む）はリーダー/owner/
--    経理のみ。一般メンバーに兄弟案件の金額が変更履歴経由で見えるのを防ぐ。
--    経費・タスクの履歴は従来どおりメンバーにも見える。
-- ============================================================
drop policy if exists audit_select on public.audit_log;
create policy audit_select on public.audit_log for select to authenticated
  using (public.is_manager()
         or (project_id is not null and public.can_see_project(project_id)
             and (table_name <> 'projects'
                  or public.is_project_owner_or_leader(project_id))));

-- ============================================================
-- 10) データ移行はしない: 既存プロジェクト5件は親のまま、既存タスクは
--    プロジェクト直下タスクとして残る。orders 3行・サブタスク（parent_task_id）も残置。
-- ============================================================
