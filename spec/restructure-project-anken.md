# プロジェクト−案件−タスク再編（2026-07-23）

背景: オフィスキャンプの実態は出来高制の業務委託の集合。個人は自分が受け持つ案件の金額・粗利を見え、プロジェクトリーダーと経理はプロジェクト全体（誰にいくら発注し、経費がいくらか）を把握する。現行の「案件−タスク−サブタスク」を「プロジェクト−案件−タスク」へ再編し、発注ページとホーム(PC)を廃止する。

## 用語とデータモデル（正）

| 新用語 | 実体 | 備考 |
|---|---|---|
| プロジェクト | projects 行で parent_id IS NULL | 旧「案件」。管理はリーダー(leader_id)と経理/管理者 |
| 案件 | projects 行で parent_id = プロジェクトid | 担当者は leader_id の一人のみ。案件金額 = amount。旧タスク追加+旧発注の後継 |
| タスク | tasks 行 | 案件直下が基本。プロジェクト直下も許容（旧データ）。サブタスク(parent_task_id)は UI 廃止・列残置 |
| メンバー | 自動導出 | プロジェクトのメンバー = 子案件の担当者集合。project_members はトリガ同期。手動追加/削除 UI 撤去 |
| 経費 | expenses 行 | プロジェクト行（親 or 子）に紐づく。申請先 charge_to を持つ。承認フロー廃止（status 列残置・UI 撤去） |
| 発注 | 廃止 | 案件割り振りに統合。orders テーブル・トリガは残置、UI から一切触らない・書き込まない |

## 金額・粗利の定義（正）

1. 案件行: 案件金額 = amount。クライアント請求 client_billed = Σ(charge_to='client' の紐づく経費)。経費 cost = Σ(charge_to≠'client' の紐づく経費)。案件粗利 = amount + client_billed − cost。
2. プロジェクト行: プロジェクト金額 = amount。案件数 anken_count。発注計 anken_sum = Σ子 amount。経費計 tree_cost = 自行+全子行の非 client 経費。クライアント請求 tree_client = 同 client 分。粗利 = amount + tree_client − tree_cost（2026-07-25 改訂・db/v19。旧定義 amount − anken_sum は経費を一切引かず、v16 以前に登録した親直下の経費が粗利に出なかった。発注計は社内配分なので粗利からは引かない）。
3. メンバー別粗利（プロジェクト詳細。リーダー/経理のみ表示）: 人 X = Σ_{Xが担当の子案件 c}(c.amount + c.client_billed) − Σ(ツリー内で charged_user_id=X の経費)。リーダー行のみ = プロジェクト金額 + 親直下の client_billed − anken_sum − Σ(charged_user_id=リーダー)。フロントで expenses 行から計算（ビュー化しない）。
4. 経費申請先の意味: self=申請者本人の負担（charged_user_id=申請者）。member=選択メンバーの負担（charged_user_id=その人）。client=先方請求（charged_user_id=null、紐づけ先の revenue に上乗せ＝粗利が増える）。

## DB 契約（db/v16-project-anken-restructure.sql、担当 gpt。冪等に書く）

1. expenses に追加: `charge_to text not null default 'self' check (charge_to in ('self','member','client'))`、`charged_user_id uuid references profiles(id)`。バックフィル `update expenses set charged_user_id = user_id where charge_to='self' and charged_user_id is null`。
2. FK 変更: expenses.project_id を on delete restrict → cascade。projects.parent_id を on delete set null → cascade（プロジェクト削除で案件・タスク・経費が全て消える）。
3. can_see_project(pid) 差し替え（security definer 維持）: is_manager() / 行の owner_id・leader_id が自分 / project_members に自分 / 親行（parent_id）の owner・leader・member に自分。
4. project_members 自動同期: 関数 sync_anken_members()（security definer）+ projects への after insert or update of leader_id, parent_id or delete トリガ。対象親（新旧両方）の project_members を「子の leader_id 集合（非null）」へ全消し全入れで再計算。手動運用は廃止（既存の手動3行は消えてよい）。
5. project_costs 再定義（security_invoker=true）: 列 = id, name, code, parent_id, leader_id, status, client, delivery_date, start_date, revenue(=amount), anken_count, anken_sum, cost(自行の非client経費のみ。**orders は算入しない**), client_billed(自行のclient経費), tree_cost, tree_client(親のみ意味を持つ。子は自行と同値), profit(親: amount−anken_sum ／ 子: amount+client_billed−cost), profit_rate(profit/revenue)。行フィルタ: can_see_project(id) かつ（親行はそのまま／子行は is_manager or 子の leader_id=自分 or 親の leader_id・owner_id=自分）＝非担当メンバーに他人の案件金額を見せない。
6. projects RLS: update/delete = owner_id or leader_id or 親の owner_id・leader_id or is_manager。insert・select は現状維持（select は can_see_project の新定義で自動的に変わる）。
7. project_task_labels（本番に ad-hoc 存在・db/ にファイル無し）を v16 で再掲・固定: `select id,name,code,status,start_date,end_date,delivery_date from projects where can_see_project(id) or is_project_task_assignee(id)`。
8. log_change() 差し替え: projects 行の audit_log.project_id を coalesce(parent_id, id) にする（案件の変更がプロジェクトの変更履歴フィードに載る）。他テーブルは現状維持。
9. データ移行: しない。既存5プロジェクトは親のまま、既存タスクはプロジェクト直下タスクとして残る。orders 3行・サブタスク0行は残置。

## shared.js 契約（担当 gpt。pc.html はこのシグネチャを前提に書く）

- `OC.loadProjects()`: 親行のみ（project_costs で parent_id is null + projects メタ結合）。anken_count / anken_sum / profit を含む。
- `OC.loadProjectDetail(id)`: `{ p, ankens, expenses, tasks, members }`。ankens = 子行（project_costs+projects 結合）。expenses = ツリー全体（select に charge_to, charged:charged_user_id(name), proj:project_id(name,parent_id) を追加）。tasks = ツリー全体。orders 取得は廃止。
- `OC.loadAnkenDetail(id)`: `{ p, tasks, expenses }`（その案件のみ）。
- `OC.addAnken(parent_id, payload)`: projects へ `{parent_id, name, leader_id, amount, start_date, end_date, note, status:'進行', owner_id:effectiveUserId()}` insert。
- `OC.addExpense(project_id, amount, note, charge_to, charged_user_id)`: 引数拡張。self のとき charged_user_id=effectiveUserId()。
- `OC.loadExpenses(limit)`: select に charge_to, charged:charged_user_id(name) を追加。
- `OC.projectOptions()`: 全可視行（親子とも）。返り値に parent_id と親名（表示は「親名 › 案件名」を組める形）。
- 削除: loadOrders / addOrder / updateOrder / deleteOrder / loadBadgeCounts / badgeSeenAt / badgeMarkSeen / addProjectMember / removeProjectMember。
- `OC.loadMyProjectIds()` / `OC._ensureVisible()`: 新可視定義へ（owner / leader / member ＋ その親子行。担当する子の親、見える親の子を含める）。
- FIELD_JP に charge_to='申請先'・charged_user_id='申請先メンバー' を追加。logLabel / diffHTML の projects 行は diff の parent_id 有無で「案件」/「プロジェクト」と表記。
- addProject / updateProject / deleteProject / loadAllTasks / タスク系 / 監査系 / メンバー管理Edge系は現状維持。

## スマホ（app.html、担当 front-A。sw.js VERSION v9→v10 も front-A）

app.html は shared.js 非依存（直クエリ61箇所）。この構造は変えず、内部実装を上記契約と同じクエリ形に揃える。

1. タブ: 経費（既定着地・維持）/ プロジェクト / タスク / 経理。s-orders セクション・発注タブ・バッジ機構（badgeExpense/badgeOrders・loadBadgeCounts 相当・oc_seen_*）を削除。applyHash の valid から 'orders' を除去。
2. s-projects → プロジェクト一覧: 親行のみ。カード/テーブルに 案件数・粗利（=金額−発注計）列を追加。追加フォームは現状踏襲（プロジェクト作成）。
3. openDetail を parent_id で分岐:
   - 親=プロジェクト詳細: KPI（プロジェクト金額 / 発注計 / 経費計 / 粗利=金額−発注計）。サブタブ = 案件 / 経費 / 情報。案件サブタブ: 子一覧（名前・担当者・金額・状態。タップで案件詳細へ）+ 案件追加フォーム（名前・担当者1人・案件金額・開始/終了）。経費: ツリー全体、申請先表示付き。情報: 従来のインライン編集 + メンバー欄は導出結果の表示のみ（追加/削除 UI 撤去）+ メンバー別粗利表（リーダー/経理のみ）+ 変更履歴（従来通り）。
   - 子=案件詳細: KPI（案件金額 / 経費 / 粗利。金額系は担当者本人・親リーダー・経理のみ）。サブタブ = タスク / 経費 / 情報。タスク: 現 taskForm / taskItemHTML を流用。経費: この案件のみ。
4. タスクタブ: `.is('parent_task_id',null)` 条件を撤去し全行表示。案件ラベルは project_task_labels 継続。taskModal 内のサブタスク UI（addSubtask/updSub/assignSub 系と描画）を削除。
5. 経費タブ: フォームに申請先 select を追加（選択肢: 自分 / 先方クライアント（請求） / 各メンバー名）。値は 'self' | 'client' | user_id。record() が charge_to / charged_user_id を insert に含める。案件選択肢は親子とも（子は「親名 › 案件名」表記）。経費一覧・詳細内の承認/差戻 UI（saveExpStatus・EXP_STATUS select・状態バッジ）を撤去し、申請先表示（自分/名前/クライアント請求）に置換。
6. 経理タブ: 一覧は親行のみ。列 = No. / プロジェクト名 / 受注元 / 状態 / 担当 / プロジェクト金額 / 発注計 / 経費計 / 粗利 / 粗利率 / 納品 / 登録。粗利=金額−発注計。行長押しシートに「削除」を追加（confirm で「案件◯件・経費◯件も削除されます」を出してから delete。cascade は DB 側）。
7. 文言: 旧「案件」の意味の箇所は「プロジェクト」へ全置換。新「案件」は子のみを指す。
8. 案件の削除: プロジェクト詳細の子一覧の長押しで削除（リーダー/経理のみ。confirm 付き）。

## PC（pc.html、担当 front-B）

1. ナビ: home・orders を削除。既定ビュー = projects（TITLES / go() / boot 末尾 / applyHash 相当を追随）。キーボードショートカット 1-4 に詰める。バッジ機構（refreshBadges/loadBadgeCounts 呼び出し）を削除。
2. projects ビュー: 左一覧 = 親行のみ。列 = プロジェクト / 案件数 / 金額 / 発注計 / 粗利 / 状態 / 担当。右詳細:
   - 親選択時: KPI（金額 / 発注計 / 経費計 / 粗利=金額−発注計）+ 案件リスト（名前・担当・金額・状態。行クリックで案件詳細へ。追加 = 名前/担当者1人/金額/期日のモーダル → OC.addAnken）+ メンバー別粗利表（リーダー/経理のみ）+ 経費一覧（ツリー全体・申請先列付き）+ 情報（インライン編集は現状踏襲。メンバーは表示のみ、addProjectMember/removeProjectMember の UI 撤去）+ 監査ログ（従来通り）。
   - 子選択時: 案件詳細（KPI: 案件金額/経費/粗利 + タスク一覧と追加 + この案件の経費 + 情報）。右クリックで案件削除（リーダー/経理）。
3. expenses ビュー: 新規モーダルに申請先 select（自分/先方クライアント（請求）/各メンバー）。一覧の状態列・承認/差戻 select・一括承認チェックボックス・bulkExpStatus を撤去し「申請先」列に置換。案件選択肢は「親名 › 案件名」。
4. finance ビュー: 一覧は親行のみ。列 = プロジェクト / 状態 / 担当 / 金額 / 発注計 / 経費計 / クライアント請求 / 粗利 / 納品。粗利=金額−発注計。各行に削除導線（右クリック finCtx + 行末ボタンのどちらでも可、confirm で「案件◯件・経費◯件も削除」）。CSV 出力の列も追随。
5. tasks ビュー: サブタスク UI（addSub/saveSubField と詳細モーダル内の描画、リスト/タイムラインのインデント表示）を撤去し全行フラット表示。タスク追加のプロジェクト選択肢は親子とも（子は「親名 › 案件名」）。
6. 文言: サイドバー「案件」→「プロジェクト」ほか、旧「案件」の意味の箇所を全置換。

## 既知の許容事項

- 変更履歴（audit_log）の projects 行はリーダー/owner/経理のみ閲覧（v16 §9）。一般メンバーが兄弟案件の金額を変更履歴 diff で見られるのを防ぐため。経費・タスクの履歴は従来どおりメンバーにも見える。
- projects テーブルへの REST 直クエリでは、親のメンバー（=案件担当者）が兄弟案件行の amount 列に到達できる（projects_select は行単位 RLS のため）。v14 の方針を踏襲し「セキュリティ境界ではなく UX スコープ」として許容。UI と project_costs ビューでは秘匿している。
- タスク詳細のメモ欄が常に空になる既存バグ（loadAllTasks 系の select に note が無い）を本再編に同乗して修正した。

## 分担・検証

- gpt: db/v16-project-anken-restructure.sql + shared.js。検証 = SQL は目視レビュー用に冪等で書く（適用はメインが run.sh で実施）。shared.js は `node --check shared.js` 相当の構文確認。
- front-A: app.html + sw.js。front-B: pc.html。相互のファイルには触らない。検証 = `python -m http.server 8788` で app.html / pc.html がコンソールエラーなく起動（ログイン画面表示まで）。
- 検収・migration 適用・push はメイン。
- 仮（ヒアリング未回答のまま進める点): スマホの既定着地は経費タブのまま／経費申請先のメンバー候補は全メンバー（プロジェクト絞りしない）／非担当メンバーに他人の案件金額・プロジェクト金額は出さない／経理一覧は親（プロジェクト）のみで案件の削除はプロジェクト詳細から。
