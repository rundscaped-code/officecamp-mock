-- ============================================================
-- v17 — プロジェクト金額の null 許容（spec/anken-page-and-edit-ux.md）
--   projects.amount = null を「金額未確定」として扱えるようにする。
--   既存行の 0 は書き換えない（0 円と未確定は意味が違う。空白化は画面から行う）。
--   project_costs は amount null の行で profit / profit_rate も null を返す。
--   anken_sum は従来どおり（sum は null を無視）。他の列・行フィルタは v16 のまま。
-- 何度流しても安全（idempotent）。
-- ============================================================

-- ============================================================
-- 1) projects.amount の not null 制約と default 0 を外す
--    （既に外れていても drop not null / drop default はエラーにならない）
-- ============================================================
alter table public.projects alter column amount drop not null;
alter table public.projects alter column amount drop default;

-- ============================================================
-- 2) project_costs 再定義（security_invoker = true。列構成・行フィルタは v16 §5 のまま）
--    v17 の変更点は金額 null の伝播のみ:
--      revenue     = 素の amount（null 可）
--      profit      = 親: amount − anken_sum ／ 子: amount + client_billed − cost
--                    （式が amount null で自然に null になるため v16 の式のまま）
--      profit_rate = revenue null なら null（v16 は else 0 に落ちていた）
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
  -- 親ごとの子案件集計（件数・発注計・子の経費）。sum は null（未確定）を無視する
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
       case when s.revenue is null then null
            when s.revenue > 0
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
    -- 粗利: 親 = 金額 − 発注計 / 子 = 金額 + クライアント請求 − 経費（金額 null なら null）
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
