# 案件ページ新設・編集UX改善（2026-07-23）

背景: 再編（restructure-project-anken.md）の追加要件。個人が自分の担当案件を1画面で見て弄れる場を作り、プロジェクト金額が未確定のケース（金額不明のまま案件だけ走る）を扱えるようにする。経費・案件の編集導線が詳細画面に無い問題も解消する。

前提: 用語・粗利定義・権限は restructure-project-anken.md が正。本 spec はその差分のみ。サブタスクは廃止済みで、タスク＝案件直下の単層。従来のタスク運用（状態・期日・担当・ボード/タイムライン/リスト）は変えない。

## DB 契約（db/v17-amount-nullable.sql）

1. projects.amount の not null 制約と default 0 を外す（null = 金額未確定）。既存行の 0 は書き換えない（0 円と未確定の意味が違うため。空白化はユーザーが画面から行う）。
2. project_costs 再定義: revenue は素の amount（null 可）。profit は amount が null なら null（親: amount − anken_sum ／ 子: amount + client_billed − cost。いずれも amount null で null）。profit_rate も同様に null。anken_sum は従来どおり（sum は null を無視）。他の列・行フィルタは v16 のまま。
3. 変更はこの2点のみ。冪等に書く。

## shared.js 契約

- `OC.loadMyAnkens()` 新設: 自分（effectiveUser）が担当（leader_id=自分）の子行一覧。project_costs の子行 + projects メタ + 親名を結合し、[{id, name, code, status, parent_id, parent_name, revenue, cost, client_billed, profit, start_date, end_date}] を返す。
- 金額 null の表示は呼び出し側で `v == null ? '—' : OC.yen(v)` と分岐する（ヘルパは増やさない）。
- 既存 API は変更なし（編集 UI は updateExpense / updateProject を使う）。

## スマホ（app.html、担当 front-A。sw.js VERSION v10→v11）

1. タブ: 経費 / プロジェクト / 案件 / タスク / 経理 の5本（経理は従来どおり権限者のみ）。applyHash の valid に 'ankens' を追加。
2. s-ankens 新設: KPI 3枚（担当案件数 / 粗利計 / 経費計。自分の担当案件の合算。金額 null の案件は粗利計に入れない）+ 案件カード一覧（案件名・紐づくプロジェクト名・状態・金額・経費・粗利。null は '—'）。タップで既存の案件詳細（openDetail の子分岐）へ。データ取得は shared.js 契約の loadMyAnkens と同形の直クエリ。
3. 経費の編集・削除: プロジェクト詳細・案件詳細・経費タブの経費行の長押しシートに「編集」「削除」（本人 or 経理のみ表示。RLS準拠）。編集は金額・メモ・申請先の3項目の小モーダル。
4. 案件行の編集: プロジェクト詳細の案件一覧行の長押しシートに「金額を編集」「状態を変更」を追加（担当本人・親リーダー/owner・経理）。金額は空欄確定で null。
5. 経費フォームの紐づけ先を2段選択に変更: 1段目=プロジェクト select、2段目=案件 select（先頭に「プロジェクト直下」、以降は選択プロジェクトの案件のみ）。1段目変更で2段目を再構築。保存される project_id は 2段目が案件ならその id、プロジェクト直下なら親 id。
6. 金額 null 対応: プロジェクト追加・編集フォームの金額は空欄可（空欄=null で保存）。一覧・KPI・経理タブで null は '—' 表示、合算から除外。案件追加フォームの金額も空欄可（null）。

## PC（pc.html、担当 front-B）

1. ナビ: プロジェクト / 案件 / 経費 / タスク / 経理 / メンバー。ショートカット 1-5。TITLES / go() / popstate / boot 追随。
2. ankens ビュー新設: KPI 3枚（担当案件数 / 粗利計 / 経費計）+ テーブル（案件 / プロジェクト / 状態 / 金額 / 経費 / 粗利 / 期間）。行クリックで go('projects') → selectAnken(parent_id, id)（タイムラインの「詳細を開く」と同じ経路）。データは OC.loadMyAnkens()。
3. 経費の編集・削除: プロジェクト詳細・案件詳細の経費一覧に、経費ビューと同じインライン編集（金額・メモ）+ 申請先 select + 右クリック削除（本人 or 経理）。編集後は当該詳細を再描画。
4. 案件行の編集: プロジェクト詳細の案件リスト行で金額・状態をその場編集（経理テーブルの fcell 方式。担当本人・親リーダー/owner・経理。金額は空欄確定で null）。
5. 経費モーダルの紐づけ先を2段選択に変更（スマホ節5と同仕様）。
6. 金額 null 対応: プロジェクト一覧・詳細KPI・経理ビュー・CSV で null は '—' 表示、KPI 合算から除外。金額セルの空欄確定で null 保存（updProjNum / saveProjField 系の parseInt NaN → null）。

## シードデータ（メインが v17 適用後に run.sh で投入）

- プロジェクト「狩尾神社 海洋散骨WEB」: amount=null, leader=小野佑真, status=進行
- 案件「コーディング・システム構築」: 担当=丹羽駿介, amount=30000
- 案件「デザイン」: 担当=小野佑真, amount=null（未確定）

## 分担・検証

- v17 + shared.js: 代替エージェント（デスクトップセッションのため gpt 不可）。`node --check shared.js`。
- front-A: app.html + sw.js ／ front-B: pc.html。相互のファイルに触らない。検証は両画面がコンソールエラーなくログイン画面まで描画。
- 適用・シード投入・検収・push はメイン。
- 仮: 案件ページは経理・管理者も自分の担当案件のみ（全社は経理ページが担う）／案件ページの粗利計・経費計は案件に紐づく経費ベース（申請先による個人負担の付け替えはプロジェクト詳細のメンバー別粗利表で見る）。
