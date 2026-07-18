-- ============================================================
-- v15 — 発注金額の後編集を受注側案件へ追随
--   UI に orders.amount の後編集が入ったため、v14 の自動生成案件
--   （内注発注時に「受注額=発注額」で作られる受注側案件）の amount が
--   取り残されて、発注元の原価と受注側の受注額が乖離する問題への対応。
--
-- 【紐付けについて】
--   v14 の order_to_task() は受注側案件を生成するが、その id をどこにも
--   記録しない（note に発注元の code を文字列で埋めるのみ。FK 無し）。
--   つまり「この発注から生成された案件」は構造上は特定できない。
--   → 代替案として orders.generated_project_id を追加して採用する:
--     1) 新規発注は order_to_task() 内で生成案件の id を記録（本ファイルで差し替え）
--     2) 既存分は v14 の生成条件（name=title / owner=to_user_id /
--        note '発注より自動生成…' / created_at 一致=同一トランザクション）で
--        バックフィル。1:1 に確定できた組だけ紐付け、曖昧な組は null のまま
--        （= 金額追随の対象外。誤リンクによる他案件の金額書き換えを避ける）。
--
-- 【安全側の判断】
--   受注側案件の amount が手で編集されていた場合の上書きは仕様判断になるため、
--   トリガは「受注側 amount が旧発注額と一致している場合のみ追随」とする。
--   手動変更済みの案件は触らない（乖離は残るが、受注側の意図的な値を守る）。
--
-- 何度流しても安全（idempotent）。
-- ============================================================

-- 1) 紐付けカラム: この発注から自動生成された受注側案件
alter table public.orders
  add column if not exists generated_project_id uuid
    references public.projects(id) on delete set null;

-- 2) order_to_task() を差し替え: 生成した案件の id を発注行に記録する。
--    v5 以来 AFTER INSERT だったが、new.generated_project_id への直接代入で
--    記録するため BEFORE INSERT に変更する（AFTER のままだと orders への
--    self-update が要り、audit_log = UI の変更履歴に発注1件ごとに余分な
--    UPDATE 行が出る）。処理内容は v14 と同一＋記録1行のみ。
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
    -- v15: 生成案件を発注に紐付け（金額追随の対象特定に使う）
    new.generated_project_id := newpid;
  end if;
  return new;
end $$;
drop trigger if exists trg_order_task on public.orders;
create trigger trg_order_task before insert on public.orders
  for each row execute function public.order_to_task();

-- 3) 既存発注のバックフィル（best effort）
--    v14 生成時は同一トランザクション内の default now() のため
--    projects.created_at = orders.created_at が厳密に一致する。
--    それでも同名・同受注者・同時刻の組が複数あり得るため、
--    発注→案件・案件→発注の両方向で候補が1件に確定した組だけ紐付ける。
with cand as (
  select o.id as order_id, p.id as project_id
  from public.orders o
  join public.projects p
    on  p.name       = o.title
    and p.owner_id   = o.to_user_id
    and p.note like '発注より自動生成%'
    and p.created_at = o.created_at
  where o.generated_project_id is null
    and o.to_user_id is not null
    -- 既に他の発注に紐付いている案件は候補にしない（再実行時の付け替え防止）
    and not exists (select 1 from public.orders o2
                    where o2.generated_project_id = p.id)
),
uniq_order as (  -- 発注側から見て候補が1件
  -- min(uuid) は PG16 未満に無いため array_agg で代用（候補1件のみ通す）
  select order_id, (array_agg(project_id))[1] as project_id
  from cand group by order_id having count(*) = 1
),
uniq_pair as (   -- 案件側から見ても1件（1:1 確定のみ）
  select u.order_id, u.project_id
  from uniq_order u
  join (select project_id from uniq_order
        group by project_id having count(*) = 1) x
    on x.project_id = u.project_id
)
update public.orders o
   set generated_project_id = u.project_id
  from uniq_pair u
 where o.id = u.order_id;

-- 4) 発注金額の後編集を受注側案件へ追随させるトリガ
--    追随条件（安全側）: 受注側 amount = 旧発注額 の場合のみ。
--    手動編集済み（値が乖離済み）の案件は上書きしない。
create or replace function public.order_amount_to_project()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.generated_project_id is not null then
    update public.projects
       set amount = coalesce(new.amount, 0)
     where id = new.generated_project_id
       and amount = coalesce(old.amount, 0);  -- 手動変更済みなら触らない
  end if;
  return new;
end $$;
drop trigger if exists trg_order_amount_sync on public.orders;
create trigger trg_order_amount_sync
  after update of amount on public.orders
  for each row
  when (old.amount is distinct from new.amount)
  execute function public.order_amount_to_project();
