-- ============================================================
-- v18 — 権限の締め直し（コードレビュー 2026-07-25）
--   1) profiles.role の自己昇格を塞ぐ
--   2) 他人のプロジェクト配下へ案件を差し込む経路を塞ぐ
--   3) タスク担当への projects 本体の開放をやめる（金額・受注元が漏れていた）
--   4) 見えない案件へのタスク・経費の書き込みを塞ぐ
--   5) 他人の所属部署の書き換えを塞ぐ
-- 何度流しても安全（idempotent）。
-- ============================================================

-- ============================================================
-- 1) profiles: 一般ユーザーが更新してよい列を name / department_id に限定する。
--    旧 profiles_update は「自分の行なら全列可」で role も書けたため、
--    誰でも自分を '管理者' に UPDATE でき、is_manager() が通ってしまった。
--    列単位 GRANT なので service_role（メンバー管理の Edge Functions）は影響を受けない。
--    行の絞り込み（自分の行だけ）は既存の profiles_update ポリシーがそのまま担う。
-- ============================================================
revoke update on public.profiles from authenticated;
grant  update (name, department_id) on public.profiles to authenticated;

-- ============================================================
-- 2) projects_insert: 自分名義、かつ「自分に見えるプロジェクトの配下」に限る。
--    旧 with check (true) だと、他人のプロジェクト id を parent_id に入れて
--    子案件を1件 insert するだけで、v16 のメンバー同期トリガが自分を
--    project_members に登録し、可視権限を自力で発行できた。
--    代理操作（管理者が対象ユーザー名義で作る）は is_manager() 側で通す。
-- ============================================================
drop policy if exists projects_insert on public.projects;
create policy projects_insert on public.projects for insert to authenticated
  with check (public.is_manager()
    or (owner_id = auth.uid()
        and (parent_id is null or public.can_see_project(parent_id))));

-- ============================================================
-- 3) projects_select: タスク担当への開放をやめる。
--    projects 本体は amount / client を含むため、v14 の意図（担当には案件名だけ、
--    金額は見せない）を project_costs ビューだけでは守れていなかった。
-- ============================================================
drop policy if exists projects_select on public.projects;
create policy projects_select on public.projects for select to authenticated
  using (public.can_see_project(id));

-- 3b) project_task_labels を security definer ビューへ戻す。
--     security_invoker = true のままだと、ビュー内の projects 参照が呼び出し元の
--     RLS（上で締めた projects_select）で先に弾かれ、案件メンバーでないタスク担当に
--     案件名が返らなくなる。行の絞り込みはビュー自身の where 句が担う。
--     公開列は名前・コード・状態・日付のみで、金額・受注元は含まない。
drop view if exists public.project_task_labels;
create view public.project_task_labels with (security_invoker = false) as
select id, name, code, status, start_date, end_date, delivery_date
from public.projects
where public.can_see_project(id) or public.is_project_task_assignee(id);

-- ============================================================
-- 4a) tasks: 見えない案件にタスクを作れないようにする。
--     旧 with check は leader_id = auth.uid() だけで通ったため、任意の案件に
--     タスクを1件作って自分をアサインすれば、その案件を読む足掛かりになった。
--     using 句（更新・削除の対象範囲）は v2 のまま。
-- ============================================================
drop policy if exists tasks_cud on public.tasks;
create policy tasks_cud on public.tasks for all to authenticated
  using (public.is_manager() or leader_id = auth.uid()
         or public.project_owner(project_id) = auth.uid())
  with check (public.can_see_project(project_id)
    and (public.is_manager() or leader_id = auth.uid()
         or public.project_owner(project_id) = auth.uid()));

-- 4b) expenses_insert: v12 で落ちた can_see_project を戻す。
--     v12 の狙いは代理操作で user_id を対象ユーザーに寄せることであり、
--     案件チェックを外すことではなかった。
drop policy if exists expenses_insert on public.expenses;
create policy expenses_insert on public.expenses for insert to authenticated
  with check ((user_id = auth.uid() or public.is_manager())
              and public.can_see_project(project_id));

-- ============================================================
-- 5) profile_departments: 自分の所属か、経理・管理者のみ変更可。
--    旧 using (true) with check (true) は他人の所属を誰でも書き換え・削除できた。
-- ============================================================
drop policy if exists pd_cud on public.profile_departments;
create policy pd_cud on public.profile_departments for all to authenticated
  using (public.is_manager() or profile_id = auth.uid())
  with check (public.is_manager() or profile_id = auth.uid());
