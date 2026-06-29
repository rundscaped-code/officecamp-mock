-- ============================================================
-- マイグレーション v4 — 納品日 / 部門 / 内注先=部門 / 非ログインのスタッフ
-- 何度流しても安全。
-- ============================================================

-- 1) 案件に納品日
alter table public.projects add column if not exists delivery_date date;

-- 2) 部門マスタ
create table if not exists public.departments (
  id   uuid primary key default gen_random_uuid(),
  name text not null unique
);
insert into public.departments(name) values
  ('デザイン部門'),('写真部門'),('建築部門'),('SE部門')
on conflict (name) do nothing;
alter table public.departments enable row level security;
drop policy if exists dept_select on public.departments;
create policy dept_select on public.departments for select to authenticated using (true);
drop policy if exists dept_cud on public.departments;
create policy dept_cud on public.departments for all to authenticated
  using (public.is_manager()) with check (public.is_manager());

-- 3) profiles に所属部門。非ログインのスタッフも登録できるよう auth FK を外す
alter table public.profiles add column if not exists department_id uuid references public.departments(id);
do $$
declare c text;
begin
  select conname into c from pg_constraint
   where conrelid='public.profiles'::regclass and contype='f'
     and confrelid='auth.users'::regclass;
  if c is not null then execute format('alter table public.profiles drop constraint %I', c); end if;
end $$;
-- id 既定値（手動 insert 用）
alter table public.profiles alter column id set default gen_random_uuid();

-- 4) orders に 内注先=部門
alter table public.orders add column if not exists to_dept_id uuid references public.departments(id);

-- 自分の所属部門か（RLS用）
create or replace function public.my_department()
returns uuid language sql stable security definer set search_path = public as $$
  select department_id from public.profiles where id = auth.uid();
$$;

-- orders 閲覧: 案件を見れる人 / 内注先本人 / 内注先部門の所属者
drop policy if exists orders_select on public.orders;
create policy orders_select on public.orders for select to authenticated
  using (public.can_see_project(project_id)
         or to_user_id = auth.uid()
         or (to_dept_id is not null and to_dept_id = public.my_department()));

-- 5) スタッフ登録：丹羽駿介→SE部門、中島津菜美→写真部門（仮メール）
update public.profiles
   set department_id = (select id from public.departments where name='SE部門')
 where email='rundscape.d@gmail.com';

insert into public.profiles(name, email, role, department_id)
select '中島津菜美','tsunami.nakajima@example.local','デザイン',
       (select id from public.departments where name='写真部門')
where not exists (select 1 from public.profiles where email='tsunami.nakajima@example.local');
