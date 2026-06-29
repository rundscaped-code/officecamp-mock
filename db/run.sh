#!/usr/bin/env bash
# officecamp Supabase マイグレーション実行ツール
# token は repo外 ~/.config/officecamp/supabase.env に置く（gitに乗らない）
# 使い方: ./run.sh db/v2.sql   /   echo "select 1" | ./run.sh -
set -euo pipefail
ENV="$HOME/.config/officecamp/supabase.env"
[ -f "$ENV" ] || { echo "ERR: $ENV が無い（SUPABASE_PAT と PROJECT_REF を入れて）"; exit 1; }
# shellcheck disable=SC1090
source "$ENV"
: "${SUPABASE_PAT:?SUPABASE_PAT未設定}"; : "${PROJECT_REF:?PROJECT_REF未設定}"

SRC="${1:-/dev/stdin}"
[ "$SRC" = "-" ] && SRC=/dev/stdin
SQL="$(cat "$SRC")"

# SQLをJSON文字列に安全にエンコードして Management API に投げる
BODY="$(SQL="$SQL" python3 -c 'import json,os;print(json.dumps({"query":os.environ["SQL"]}))')"
curl -sS -X POST \
  "https://api.supabase.com/v1/projects/${PROJECT_REF}/database/query" \
  -H "Authorization: Bearer ${SUPABASE_PAT}" \
  -H "Content-Type: application/json" \
  -d "$BODY"
echo
