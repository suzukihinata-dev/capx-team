#!/usr/bin/env bash
#SBATCH --job-name=capx-integration
#SBATCH --gpus=1
#SBATCH --time=02:00:00
# 統合ビルド（§4.4 の 5〜6）: 指定コミットから提出イメージを作り、スモークテストまで通す。誰でも実行できる。
#   integration_build.sh --commit <sha|tag> [--source-dir DIR] [--sim robosuite|libero|none]
# 手元で編集したスクリプトではなく、指定コミットの env/jobs/ を使うこと。
# このスクリプトは、自分自身が指定コミットの内容と一致しない場合は止まる。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/common.sh"
COMMIT="" SRCDIR="" SIM=robosuite
ARGS=("$@")
while [[ $# -gt 0 ]]; do case "$1" in
  --commit) COMMIT="$2"; shift 2;; --source-dir) SRCDIR="$2"; shift 2;; --sim) SIM="$2"; shift 2;;
  *) die "不明な引数: $1";; esac; done
[[ -n "$COMMIT" ]] || die "--commit は必須です"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/capx-int.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
FULL="$(prepare_source "$COMMIT" "$WORK/src" "$SRCDIR")"
# 自分自身（実行中のジョブスクリプト一式）が指定コミットのものと一致するか
for f in common.sh build_agent.sh smoke_test.sh integration_build.sh; do
  cmp -s "$HERE/$f" "$WORK/src/env/jobs/$f" || die "実行中の $f が指定コミットの内容と異なります（指定コミットの env/jobs/ を使ってください）"
done
load_versions "$WORK/src"
note "integration: commit=$FULL protocol=$JOB_PROTOCOL_VERSION"
SIF="$(bash "$HERE/build_agent.sh" --commit "$FULL" ${SRCDIR:+--source-dir "$SRCDIR"} | tail -1)"
bash "$HERE/smoke_test.sh" --sif "$SIF" --commit "$FULL" ${SRCDIR:+--source-dir "$SRCDIR"} --sim "$SIM"
echo "integration OK: $SIF"
echo "提出候補にする場合のタグ注釈（出自）:"
python3 "$HERE/../tools/provenance.py" --sif "$SIF" --commit "$FULL" --models-lock "$WORK/src/agent/models.lock"
