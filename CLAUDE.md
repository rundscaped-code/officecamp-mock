# officecamp-mock

オフィスキャンプ社内のプロジェクト・案件・経費・タスク管理アプリ。Supabase（Auth/DB/RLS/Edge Functions）＋ビルド無し静的フロント、PWA。

- dev 起動: repo ルートで `python -m http.server 8788` → http://localhost:8788/app.html
- 本番: https://rundscaped-code.github.io/officecamp-mock/ （master へ push すると GitHub Pages が自動反映。repo は public）
- 主要ディレクトリ:
  - ルート直下＝フロント本体。`app.html`（スマホ）/ `pc.html`（PC）/ `shared.js`（Supabase データ層。両 UI 共有）/ `config.js`（接続先と anon key）/ `sw.js`（PWA シェル。シェル変更時は VERSION を上げる）
  - `db/` ＝ SQL migrations。適用は `db/run.sh`（Supabase Management API。PAT は `~/.config/officecamp/supabase.env`）
  - `supabase/functions/` ＝ メンバー管理系 Edge Functions（管理者限定、service role 使用）
