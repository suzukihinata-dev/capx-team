#!/usr/bin/env bash
#SBATCH --job-name=capx-build-base
#SBATCH --gpus=1
#SBATCH --time=04:00:00
# 基盤イメージ（base.sif）を指定コミットの定義からビルドする（環境担当が実行）。
#   build_base.sh --commit <sha|tag> --tag base-YYYYMMDD.N [--source-dir DIR] [--out DIR]
# 出力: <out>/<tag>.sif と、env/images.lock に追記する行（ここでは書き込まない。PR で反映する）。
# 配置（グループ領域の images/ へ）は images.lock の PR がマージされた後に place_base.sh で行う。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/common.sh"

COMMIT="" TAG="" SRCDIR="" OUT="$CAPX_DATA/build"
while [[ $# -gt 0 ]]; do case "$1" in
  --commit) COMMIT="$2"; shift 2;; --tag) TAG="$2"; shift 2;;
  --source-dir) SRCDIR="$2"; shift 2;; --out) OUT="$2"; shift 2;;
  *) die "不明な引数: $1";; esac; done
[[ -n "$COMMIT" && -n "$TAG" ]] || die "--commit と --tag は必須です"
[[ "$TAG" =~ ^base-[0-9]{8}\.[0-9]+$ ]] || die "--tag は base-YYYYMMDD.N の形式にしてください"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/capx-base.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
CTX="$WORK/ctx"; mkdir -p "$CTX/official"
FULL="$(prepare_source "$COMMIT" "$WORK/src" "$SRCDIR")"
cp -a "$WORK/src/env" "$CTX/env"
load_versions "$WORK/src"
REC="$(make_record_dir "$FULL" base)"
note "commit=$FULL tag=$TAG record=$REC"

# 公式リポジトリ（設定されていれば固定コミットを取得。トークンはビルドに渡さない）
if [[ -n "${OFFICIAL_REPO_URL:-}" ]]; then
  [[ -n "${OFFICIAL_COMMIT:-}" ]] || die "OFFICIAL_COMMIT が未設定です"
  git clone -q --no-checkout "$(auth_url "$OFFICIAL_REPO_URL")" "$WORK/official.git" || die "公式リポジトリの取得に失敗"
  git -C "$WORK/official.git" archive --format=tar "$OFFICIAL_COMMIT" | tar -x -C "$CTX/official"
  echo "$OFFICIAL_COMMIT" > "$CTX/official/.capx_commit"
  if [[ -s "$CTX/env/eval_code.sha256" ]]; then
    python3 "$CTX/env/tools/eval_code_hash.py" verify --root "$CTX/official" --list "$CTX/env/eval_code.sha256" | tee "$REC/eval_code_verify.txt"
  fi
fi

mkdir -p "$OUT"
SIF="$OUT/$TAG.sif"
[[ -e "$SIF" ]] && die "既に存在します（上書きしない）: $SIF"
BUILD_ARGS=(--build-arg "CTX=$CTX" --build-arg "BASE_TAG=$TAG"
  --build-arg "BASE_IMAGE=$BASE_IMAGE" --build-arg "BASE_IMAGE_REPO=${BASE_IMAGE%:*}" --build-arg "BASE_IMAGE_DIGEST=$BASE_IMAGE_DIGEST"
  --build-arg "UV_VERSION=$UV_VERSION" --build-arg "ROBOSUITE_PYTHON=$ROBOSUITE_PYTHON"
  --build-arg "LIBERO_PYTHON=$LIBERO_PYTHON" --build-arg "LIBERO_REPO=$LIBERO_REPO"
  --build-arg "LIBERO_COMMIT=$LIBERO_COMMIT")
note "build: $SIF"
t0=$(date +%s)
"$APPTAINER" build --fakeroot "${BUILD_ARGS[@]}" "$SIF" "$CTX/env/base.def" > "$REC/build.log" 2>&1 \
  || { tail -50 "$REC/build.log" >&2; die "ビルド失敗（$REC/build.log）"; }
SECS=$(( $(date +%s) - t0 ))
SHA="$(sha256sum "$SIF" | cut -d' ' -f1)"
SIZE="$(stat -c %s "$SIF")"
"$APPTAINER" exec "$SIF" cat /opt/capx/versions.installed > "$REC/versions.installed" || true
"$APPTAINER" exec "$SIF" cat /opt/capx/apt.installed > "$REC/apt.installed" || true
LOCKLINE="$TAG $SHA $SIZE $FULL"
echo "$LOCKLINE" > "$REC/images.lock.line"
write_meta "$REC" kind=build_base commit="$FULL" tag="$TAG" sif="$SIF" sha256="$SHA" size="$SIZE" seconds="$SECS" \
  job_protocol_version="$JOB_PROTOCOL_VERSION"
seal_record "$REC"
note "完了 ($SECS s)。env/images.lock に次の行を追加する PR を出してください:"
echo "$LOCKLINE"
