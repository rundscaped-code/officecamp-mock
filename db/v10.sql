-- v10: ユーザーの複数所属部署（最大3）＋ 内注の担当者指定
-- 何度流しても安全（冪等）

-- 1) 多対多の所属テーブル
create table if not exists public.profile_departments (
  profile_id    uuid not null references public.profiles(id)    on delete cascade,
  department_id uuid not null references public.departments(id) on delete cascade,
  primary key (profile_id, department_id)
);

alter table public.profile_departments enable row level security;
drop policy if exists pd_select on public.profile_departments;
create policy pd_select on public.profile_departments
  for select to authenticated using (true);
drop policy if exists pd_cud on public.profile_departments;
create policy pd_cud on public.profile_departments
  for all to authenticated using (true) with check (true);

-- 2) 既存の単一所属（profiles.department_id）を移行
insert into public.profile_departments(profile_id, department_id)
select id, department_id from public.profiles
where department_id is not null
on conflict do nothing;

-- 3) 1人につき最大3部署までに制限
create or replace function public.enforce_max_depts() returns trigger
language plpgsql as $$
begin
  if (select count(*) from public.profile_departments
        where profile_id = new.profile_id) >= 3 then
    raise exception '1人につき所属部署は最大3つまでです';
  end if;
  return new;
end $$;
drop trigger if exists trg_max_depts on public.profile_departments;
create trigger trg_max_depts before insert on public.profile_departments
  for each row execute function public.enforce_max_depts();

-- 4) orders.to_user_id（内注の担当者）— 無ければ追加
alter table public.orders
  add column if not exists to_user_id uuid references public.profiles(id);
