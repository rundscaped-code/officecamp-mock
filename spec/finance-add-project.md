# 経理ページからの案件追加（2026-07-20）

背景: 運用上、経理ページが案件一覧の実質マスター。案件追加のたびに案件タブへ移動する手間をなくす。

## 契約

### PC（pc.html）

1. 経理ビューの topActions に「＋ 案件を追加」ボタンを置く。クリックで既存の `openProjModal()` を開く（フォームの新設はしない）。
   - 配置は `renderFinance()` 内、経理権限ゲート通過後。非経理はビュー自体が見えないため出し分け不要。
   - `go()` がビュー切替時に topActions を空にするため、renderFinance 側で毎回セットする。
2. `saveProj()` の末尾再描画に経理ビューを追加する: `curView==='finance'` なら `renderFinance(document.getElementById('content'))` を呼び、追加した案件が即座に一覧へ載る。既存の `curView==='projects'` 分岐は変えない。

### スマホ（app.html）

3. 経理セクションのヘッダ（`#s-finance` の `.head` 内）に「＋ 案件を追加」ボタンを置く。クリックで `nav('projects');toggleProjForm(true)`（ホーム画面 531 行の既存導線と同じ。経理スプレッドシートは横長でインライン追加フォームが収まらないため、既存フォームへ1タップで飛ばす）。
   - 見た目は `.head` 内で `h1`・`.date` の右に収まる `btn` 系の小さめボタン。既存の head レイアウトを崩さない。

### PWA（sw.js）

4. app.html はプレキャッシュ対象のため `VERSION` を v7 → v8 に上げる。

## 分担・検証

- 実装: front（全変更がブラウザ描画層）。
- 検証: `python -m http.server 8788` → http://localhost:8788/pc.html と /app.html がコンソールエラーなく起動すること。経理ビューの実挙動（ボタン表示・追加→一覧反映）はログイン後の実機確認。
