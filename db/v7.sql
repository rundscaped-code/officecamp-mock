-- v7: 案件リーダー（既定=登録者）
alter table public.projects add column if not exists leader_id uuid references public.profiles(id);
update public.projects set leader_id = owner_id where leader_id is null;
