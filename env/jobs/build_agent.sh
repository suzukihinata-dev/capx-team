#!/usr/bin/env bash
#SBATCH --job-name=capx-build-agent
#SBATCH --gpus=1
#SBATCH --time=01:00:00
# 提出イメージ（agent.sif）を指定コミットからビルドする（誰でも実行できる）。
#   build_agent.sh --commit <sha|tag> [--source-dir DIR] [--out DIR]
# 使う基盤イメージは、そのコミットの env/images.lock の最後の行。images/ に配置済みのものを使い、
# サイズと更新日時を記録と照合する（不一致なら止まる）。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/common.sh"
COMMIT="" SRCDIR="" OUT="$CAPX_DATA/build"
while [[ $# -gt 0 ]]; do case "$1" in
  --commit) COMMIT="$2"; shift 2;; --source-dir) SRCDIR="$2"; shift 2;; --out) OUT="$2"; shift 2;;
  *) die "不明な引数: $1";; esac; done
[[ -n "$COMMIT" ]] || die "--commit は必須です"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/capx-agent.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
FULL="$(prepare_source "$COMMIT" "$WORK/src" "$SRCDIR")"
load_versions "$WORK/src"
LOCK="$WORK/src/env/images.lock"
line="$(grep -v '^#' "$LOCK" | grep -v '^\s*$' | tail -1 || true)"
[[ -n "$line" ]] || die "env/images.lock に基盤イメージの記録がありません"
read -r BTAG BSHA BSIZE _ <<<"$line"
BASE_SIF="$CAPX_DATA/images/base-$BTAG.sif"
[[ -f "$BASE_SIF" ]] || die "基盤イメージが配置されていません: $BASE_SIF"
[[ "$(stat -c %s "$BASE_SIF")" == "$BSIZE" ]] || die "基盤イメージのサイズが images.lock と一致しません"
MODELS_SHA="$(sha256sum "$WORK/src/agent/models.lock" | cut -d' ' -f1)"
REC="$(make_record_dir "$FULL" agent)"
mkdir -p "$OUT"; SIF="$OUT/agent-${FULL:0:12}-${JOB_ID}.sif"
note "commit=$FULL base=$BTAG -> $SIF"
t0=$(date +%s)
"$APPTAINER" build --fakeroot \
  --build-arg "BASE_SIF=$BASE_SIF" --build-arg "CTX=$WORK/src" --build-arg "SOURCE_COMMIT=$FULL" \
  --build-arg "BASE_TAG=$BTAG" --build-arg "MODELS_LOCK_SHA256=$MODELS_SHA" \
  --build-arg "JOB_PROTOCOL_VERSION=$JOB_PROTOCOL_VERSION" \
  "$SIF" "$WORK/src/env/agent.def" > "$REC/build.log" 2>&1 || { tail -50 "$REC/build.log" >&2; die "ビルド失敗"; }
SECS=$(( $(date +%s) - t0 ))
SHA="$(sha256sum "$SIF" | cut -d' ' -f1)"
"$APPTAINER" inspect --labels "$SIF" > "$REC/labels.txt"
write_meta "$REC" kind=build_agent commit="$FULL" base_tag="$BTAG" base_sha256="$BSHA" models_lock_sha256="$MODELS_SHA" \
  sif="$SIF" sha256="$SHA" seconds="$SECS" job_protocol_version="$JOB_PROTOCOL_VERSION"
seal_record "$REC"
echo "$SIF"
