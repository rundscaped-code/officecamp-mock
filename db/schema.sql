-- ============================================================
-- オフィスキャンプ 案件管理アプリ — DBスキーマ v0
-- Supabase (PostgreSQL) 用。SQL Editor にそのまま貼って実行する。
-- 設計方針：小さく始めて後で足せる。社内利用なので閲覧は全員可、
-- 書き込みは本人のみ、ステータス変更は経理/管理者のみ。
-- ============================================================

-- 拡張（uuid生成）。Supabaseは既定で有効なことが多いが念のため。
create extension if not exists "pgcrypto";

-- ---- 列挙型 ------------------------------------------------
do $$ begin
  create type user_role     as enum ('建築','デザイン','SE','経理','管理者');
exception when duplicate_object then null; end $$;

do $$ begin
  create type project_status as enum ('見込','進行','完了','失注');
exception when duplicate_object then null; end $$;

do $$ begin
  create type expense_status as enum ('申請','承認','差戻');
exception when duplicate_object then null; end $$;

-- ============================================================
-- 1. profiles（社員）— Supabase Auth の auth.users と1対1
--    auth.users には列を足せないので profiles を別に持つ慣習。
-- ============================================================
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  name       text not null default '',
  role       user_role not null default 'SE',
  email      text,
  created_at timestamptz not null default now()
);

-- サインアップ時に profiles を自動作成するトリガ
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name, email)
  values (new.id, coalesce(new.raw_user_meta_data->>'name',''), new.email)
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 経理/管理者か判定するヘルパ（RLSで使用）
create or replace function public.is_manager()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role in ('経理','管理者')
  );
$$;

-- ============================================================
-- 2. projects（案件）
-- ============================================================
create table if not exists public.projects (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  client     text,
  amount     integer not null default 0,          -- 受注金額（円）
  start_date date,
  end_date   date,
  owner_id   uuid references public.profiles(id),  -- 取ってきた人
  status     project_status not null default '見込',
  note       text,
  created_at timestamptz not null default now()
);
create index if not exists idx_projects_status on public.projects(status);

-- ============================================================
-- 3. expenses（経費）— その場入力の主役
-- ============================================================
create table if not exists public.expenses (
  id          uuid primary key default gen_random_uuid(),
  project_id  uuid not null references public.projects(id) on delete restrict,
  user_id     uuid not null references public.profiles(id) default auth.uid(),
  amount      integer not null check (amount >= 0),
  note        text,
  receipt_url text,                               -- Storage上のレシート画像
  spent_at    timestamptz not null default now(),
  status      expense_status not null default '申請',
  created_at  timestamptz not null default now()
);
create index if not exists idx_expenses_project on public.expenses(project_id);
create index if not exists idx_expenses_user    on public.expenses(user_id);

-- ============================================================
-- 4. events（予定）— Googleカレンダーと連携
-- ============================================================
create table if not exists public.events (
  id            uuid primary key default gen_random_uuid(),
  project_id    uuid references public.projects(id) on delete set null,
  user_id       uuid not null references public.profiles(id) default auth.uid(),
  title         text not null,
  start_at      timestamptz not null,
  end_at        timestamptz,
  gcal_event_id text,                             -- Google側ID（双方向連携の鍵）
  created_at    timestamptz not null default now()
);
create index if not exists idx_events_start on public.events(start_at);

-- ============================================================
-- 5. 集計ビュー — 案件ごとの原価・粗利
--    expenses を project_id で合算して粗利を出す。
-- ============================================================
create or replace view public.project_costs as
select
  p.id,
  p.name,
  p.amount                              as revenue,        -- 受注
  coalesce(sum(e.amount), 0)            as cost,            -- 原価（経費計）
  p.amount - coalesce(sum(e.amount), 0) as profit,         -- 粗利
  case when p.amount > 0
       then round((p.amount - coalesce(sum(e.amount),0))::numeric / p.amount * 100, 1)
       else 0 end                       as profit_rate      -- 粗利率(%)
from public.projects p
left join public.expenses e on e.project_id = p.id
group by p.id;

-- ============================================================
-- 6. Row Level Security（行レベル権限）
--    社内ツール前提：閲覧は認証済み全員、書込みは本人、
--    ステータス変更は経理/管理者。
-- ============================================================
alter table public.profiles enable row level security;
alter table public.projects enable row level security;
alter table public.expenses enable row level security;
alter table public.events   enable row level security;

-- profiles：全員が閲覧可、自分の行だけ更新可
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated using (true);
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- projects：全員閲覧可、作成は誰でも、更新/削除は所有者か経理/管理者
drop policy if exists projects_select on public.projects;
create policy projects_select on public.projects for select to authenticated using (true);
drop policy if exists projects_insert on public.projects;
create policy projects_insert on public.projects for insert to authenticated with check (true);
drop policy if exists projects_update on public.projects;
create policy projects_update on public.projects for update to authenticated
  using (owner_id = auth.uid() or public.is_manager());
drop policy if exists projects_delete on public.projects;
create policy projects_delete on public.projects for delete to authenticated
  using (owner_id = auth.uid() or public.is_manager());

-- expenses：全員閲覧可（原価を皆が見られる要件）、作成は本人、
--           本人は自分の申請を編集可、ステータス変更は経理/管理者
drop policy if exists expenses_select on public.expenses;
create policy expenses_select on public.expenses for select to authenticated using (true);
drop policy if exists expenses_insert on public.expenses;
create policy expenses_insert on public.expenses for insert to authenticated
  with check (user_id = auth.uid());
drop policy if exists expenses_update on public.expenses;
create policy expenses_update on public.expenses for update to authenticated
  using (user_id = auth.uid() or public.is_manager());
drop policy if exists expenses_delete on public.expenses;
create policy expenses_delete on public.expenses for delete to authenticated
  using (user_id = auth.uid() or public.is_manager());

-- events：全員閲覧可、作成/編集/削除は本人
drop policy if exists events_select on public.events;
create policy events_select on public.events for select to authenticated using (true);
drop policy if exists events_cud on public.events;
create policy events_cud on public.events for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ============================================================
-- 7. 動作確認用シード（任意）— 本番前のテスト用。要らなければ消す。
--    ※ owner_id/user_id は実ユーザー作成後に手で埋める想定。
-- ============================================================
-- insert into public.projects (name, client, amount, status) values
--   ('○○ビル改修','◇◇建設', 2000000, '進行'),
--   ('△△邸 デザイン', null, 800000, '見込');
