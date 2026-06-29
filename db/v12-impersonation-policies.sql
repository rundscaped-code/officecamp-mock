-- v12: 管理者/経理が代理操作中に、対象ユーザー名義で経費・発注を作成できるようにする
-- 画面上は管理者セッションのまま、user_id / from_user は代理先ユーザーに寄せる。

drop policy if exists expenses_insert on public.expenses;
create policy expenses_insert on public.expenses for insert to authenticated
  with check (user_id = auth.uid() or public.is_manager());

drop policy if exists orders_insert on public.orders;
create policy orders_insert on public.orders for insert to authenticated
  with check ((from_user = auth.uid() or public.is_manager()) and public.can_see_project(project_id));

