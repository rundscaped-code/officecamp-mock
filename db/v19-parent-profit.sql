-- ============================================================
-- v19 — プロジェクト（親）の粗利に経費を反映する
--   旧: 親の粗利 = 金額 − 発注計。経費が一切引かれず、v16 以前に登録した経費は
--       すべて親行にぶら下がっているため、既存プロジェクトの粗利が実態より多く出ていた。
--   新: 親の粗利 = 金額 ＋ クライアント請求（自行＋子） − 経費（自行＋子）
--       ＝ 案件（子）と同じ式を、ツリー全体の集計に対して適用する。
--   発注計（anken_sum）は社内での配分なので粗利からは引かない。列は従来どおり残す。
--   案件（子）の式は変更しない（案件費 ＋ クライアント請求 − 経費）。
--   列構成と行フィルタは v17 のまま。何度流しても安全（idempotent）。
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
    -- 粗利（v19）: 親 = 金額 ＋ tree_client − tree_cost / 子 = 金額 ＋ client_billed − cost
    -- どちらも金額 null なら null。tree_* を select 内で再参照できないため式を展開している。
    case when p.parent_id is null
         then p.amount
              + coalesce(e.client_billed, 0) + coalesce(k.kids_client, 0)
              - coalesce(e.cost, 0)          - coalesce(k.kids_cost, 0)
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
