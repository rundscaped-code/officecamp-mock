# 案件タブの自己スコープ化（2026-07-20）

背景: 経理ページ＝全社マスターシート（経理・管理者のみ、全案件）。対して案件タブは、経理・管理者であっても「自分の案件」だけを見る場にする。現状は経理・管理者だと案件タブにも全件が出る（RLS が is_manager に全開のため）。

## 定義

「自分の案件」＝以下のいずれかに該当する案件:
- owner_id が自分
- leader_id が自分
- project_members に自分がいる
- いずれかのタスクの task_assignees に自分がいる

## 契約

### 共通方針

- 絞り込みは案件タブの一覧描画だけに適用する。経理タブ・経費・タスク・発注・ホーム・案件選択ドロップダウン（派生元・経費/発注フォーム）は変えない（承認系業務は全件が正）。
- セキュリティ境界ではなく UX スコープ（経理・管理者は信頼済み）。RLS は変更しない。
- 非管理者は現状維持（RLS で既に絞られている）。フィルタは isManager のときだけ適用する。
- 経理タブから他人の案件詳細を開く導線は生かす: PC は selectProject(id)、スマホは openDetail(id) が一覧に依存しないため、そのまま動く。

### PC（shared.js + pc.html）

1. shared.js: `OC.myProjIds = null;` と `OC.loadMyProjectIds()` を追加。effectiveUserId で上記4クエリ（projects.owner_id / projects.leader_id / project_members.user_id / task_assignees→task_id(project_id)）を並列実行し Set を `OC.myProjIds` に格納して返す。`OC.resetScope()` で `OC.myProjIds = null` も戻す。
2. pc.html `projFiltered()`: 先頭条件に `if(OC.isManager()&&OC.myProjIds&&!OC.myProjIds.has(p.id))return false;` を追加。
3. pc.html `renderProjects()`: `paintProjTable()` の前に `if(OC.isManager()){try{await OC.loadMyProjectIds();}catch(e){}}`（失敗時は絞らず全件表示に落とす＝業務停止させない）。
4. pc.html `saveProj()` と `duplicateProjectUI()`: `OC.projectOptions()` の後・再描画の前に同じ再取得を入れる（追加・複製直後の自案件が一覧に即載るように）。

### スマホ（app.html）

5. `loadProjects()`: projRows 構築後、`isManager()` なら me.id で同じ4クエリを実行し projRows を絞る。クエリ失敗時は絞らず全件のまま。addProject → loadProjects の既存経路で追加直後も反映される。

### PWA（sw.js）

6. app.html 変更のため VERSION v8 → v9。

## 既知の許容事項

- PC で経理タブから他人の案件詳細を開いた後、案件タブの検索・状態フィルタを操作すると詳細ペインが閉じる（paintProjTable の残留クリア既存仕様）。頻度が低いため許容。

## 分担・検証

- 実装: front。RLS 変更なし（gpt 不要）。
- 検証: pc.html / app.html がコンソールエラーなく起動。実挙動（経理ロールで案件タブ＝自分の案件のみ、経理タブ＝全件）はログイン後の実機確認。
