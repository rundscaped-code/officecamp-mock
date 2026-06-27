-- レシート画像の保存先（Supabase Storage）。SQL Editor で実行する。
-- バケットは非公開。閲覧は署名付きURL経由。

insert into storage.buckets (id, name, public)
values ('receipts', 'receipts', false)
on conflict (id) do nothing;

-- 認証済みユーザーは自分のフォルダ（先頭が自分のuid）にアップロード可
drop policy if exists receipts_insert on storage.objects;
create policy receipts_insert on storage.objects for insert to authenticated
  with check (
    bucket_id = 'receipts'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- 認証済みユーザーは receipts バケットを閲覧可（社内ツール前提）
drop policy if exists receipts_select on storage.objects;
create policy receipts_select on storage.objects for select to authenticated
  using (bucket_id = 'receipts');

-- 自分がアップロードしたものは削除可
drop policy if exists receipts_delete on storage.objects;
create policy receipts_delete on storage.objects for delete to authenticated
  using (bucket_id = 'receipts' and owner = auth.uid());
