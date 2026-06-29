-- ============================================================
-- マイグレーション v6 — 案件番号(+派生命名) / タスクのメモ
-- 命名規則: 親=OC-0001, OC-0002… / 派生=親コード-1, -2…
-- 何度流しても安全。
-- ============================================================

alter table public.projects add column if not exists code      text;
alter table public.projects add column if not exists parent_id uuid references public.projects(id) on delete set null;
alter table public.tasks    add column if not exists note      text;

create sequence if not exists public.project_code_seq;

create or replace function public.assign_project_code()
returns trigger language plpgsql security definer set search_path = public as $$
declare pcode text; n int;
begin
  if new.code is null or new.code = '' then
    if new.parent_id is not null then
      select code into pcode from public.projects where id = new.parent_id;
      select count(*) into n from public.projects where parent_id = new.parent_id;
      new.code := coalesce(pcode,'OC') || '-' || (n+1)::text;
    else
      new.code := 'OC-' || lpad(nextval('public.project_code_seq')::text, 4, '0');
    end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_project_code on public.projects;
create trigger trg_project_code before insert on public.projects
  for each row execute function public.assign_project_code();

-- 既存案件にコードを後付け（親→作成順）
do $$
declare r record;
begin
  for r in select id from public.projects where code is null and parent_id is null order by created_at loop
    update public.projects set code='OC-'||lpad(nextval('public.project_code_seq')::text,4,'0') where id=r.id;
  end loop;
  for r in select id, parent_id from public.projects where code is null and parent_id is not null order by created_at loop
    update public.projects p set code=(select code from public.projects where id=r.parent_id)||'-'||
      (1 + (select count(*) from public.projects c where c.parent_id=r.parent_id and c.created_at < p.created_at))::text
      where p.id=r.id;
  end loop;
end $$;

-- 集計ビューにも code/parent_id を載せる
drop view if exists public.project_costs;
create view public.project_costs as
select
  p.id, p.name, p.code, p.parent_id,
  p.amount                                            as revenue,
  (coalesce(e.cost,0) + coalesce(o.cost,0))           as cost,
  (coalesce(e.out,0)  + coalesce(o.out,0))            as outsource,
  (p.amount - (coalesce(e.cost,0)+coalesce(o.cost,0))) as profit,
  case when p.amount > 0
    then round((p.amount - (coalesce(e.cost,0)+coalesce(o.cost,0)))::numeric / p.amount * 100, 1)
    else 0 end                                        as profit_rate
from public.projects p
left join (select project_id, sum(amount) as cost, sum(amount) filter (where kind='外注') as out
           from public.expenses group by project_id) e on e.project_id = p.id
left join (select project_id, sum(amount) as cost, sum(amount) filter (where kind='外注') as out
           from public.orders   group by project_id) o on o.project_id = p.id;
