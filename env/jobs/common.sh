# shellcheck shell=bash
# ジョブスクリプト共通の関数。各スクリプトから source する。
# 手動実行（ローカル PC）と Slurm（GMO 計算ノード）の両方で同じ手順になるようにする。
#
# 環境変数:
#   CAPX_DATA      作業用データの置き場所（ローカル: ~/capx-data、GMO: グループ領域の capx/ を指定）
#   CAPX_REPO_URL  チーム開発リポジトリの URL（--source-dir を使わない場合に取得し直す元）
#   CAPX_TOKEN_DIR トークンの置き場所（既定: ~/.config/capx。グループ領域には置かない）

set -euo pipefail

CAPX_DATA="${CAPX_DATA:-$HOME/capx-data}"
CAPX_TOKEN_DIR="${CAPX_TOKEN_DIR:-$HOME/.config/capx}"
JOB_ID="${SLURM_JOB_ID:-local$$}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
APPTAINER="${APPTAINER:-apptainer}"
# ビルドの作業領域。/tmp は nodev 等でビルドに失敗することがあるため、データ領域の下を使う。
export APPTAINER_TMPDIR="${APPTAINER_TMPDIR:-$CAPX_DATA/tmp}"
mkdir -p "$APPTAINER_TMPDIR"

die()  { echo "ERROR: $*" >&2; exit 1; }
note() { echo "[$(date -u +%H:%M:%S)] $*" >&2; }

# トークンをファイルから読む（無ければ空）。値を表示・記録しない。
read_token() { local f="$CAPX_TOKEN_DIR/$1"; [[ -r "$f" ]] && tr -d '\n' <"$f" || true; }

# git の認証付き URL を作る（GitHub のみ。トークンはプロセス内だけで使う）
auth_url() {
  local url="$1" tok; tok="$(read_token github_token)"
  if [[ -n "$tok" && "$url" == https://github.com/* ]]; then echo "https://x-access-token:${tok}@${url#https://}"; else echo "$url"; fi
}

# 指定コミットのソースを用意する。
#   prepare_source <commit> <dest>          CAPX_REPO_URL から新しく取得し直す
#   prepare_source <commit> <dest> <srcdir> ログインノード等で取得済みのディレクトリを使う（§4.7）
# どちらも HEAD が指定コミットと一致し、未コミットの変更がないことを確かめる。
prepare_source() {
  local commit="$1" dest="$2" srcdir="${3:-}"
  if [[ -n "$srcdir" ]]; then
    [[ -d "$srcdir/.git" ]] || die "--source-dir に git リポジトリがありません: $srcdir"
    local head; head="$(git -C "$srcdir" rev-parse HEAD)"
    [[ "$head" == "$(git -C "$srcdir" rev-parse "$commit^{commit}")" ]] || die "--source-dir の HEAD ($head) が指定コミット ($commit) と一致しません"
    [[ -z "$(git -C "$srcdir" status --porcelain)" ]] || die "--source-dir に未コミットの変更があります"
    git -C "$srcdir" archive --format=tar "$head" | (mkdir -p "$dest" && tar -x -C "$dest")
    echo "$head"
  else
    [[ -n "${CAPX_REPO_URL:-}" ]] || die "CAPX_REPO_URL か --source-dir を指定してください"
    local tmp; tmp="$(mktemp -d)"
    git clone -q --no-checkout "$(auth_url "$CAPX_REPO_URL")" "$tmp/repo" 2>/dev/null || die "取得に失敗: $CAPX_REPO_URL"
    local full; full="$(git -C "$tmp/repo" rev-parse "$commit^{commit}")" || die "コミットが見つかりません: $commit"
    git -C "$tmp/repo" archive --format=tar "$full" | (mkdir -p "$dest" && tar -x -C "$dest")
    rm -rf "$tmp"
    echo "$full"
  fi
}

# 版ファイルを読み、apptainer build の --build-arg 引数を作る
load_versions() { set -a; source "$1/env/versions.submission.env"; set +a; }

# 実行記録のディレクトリ（実行ごとに一意。上書きしない）
make_record_dir() {
  local commit="$1" kind="$2" d
  d="$CAPX_DATA/records/${commit:0:12}/${JOB_ID}-${STAMP}-${kind}"
  mkdir -p "$d"; echo "$d"
}

# 実行記録のメタデータ（JSON）。トークンは書かない。実行者は CAPX_OPERATOR（担当記号）で書く。
write_meta() {
  local dir="$1"; shift
  python3 - "$dir/meta.json" "$@" <<'PY'
import json, os, sys, platform, time
out, *kv = sys.argv[1:]
meta = dict(x.split("=", 1) for x in kv)
meta.update(job_id=os.environ.get("SLURM_JOB_ID", "local"), host=platform.node(),
            operator=os.environ.get("CAPX_OPERATOR", "unset"), utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
json.dump(meta, open(out, "w"), ensure_ascii=False, indent=2)
PY
}

# 実行記録の SHA-256 一覧（受入判定の根拠として、結果リポジトリへ移す）
seal_record() { (cd "$1" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS); }

# ネットワークを遮断してコンテナを実行する。次の順に試し、最初に通った方法を使う（§4.4）。
#   a) --net --network none   b) a に --fakeroot を併用   c) unshare -rn（lo を上げてから）
# 判定: 外部（1.1.1.1:443）へ接続できず、127.0.0.1 は使えること。
NETMODE_FILE="$CAPX_DATA/.netmode"
_net_probe='import socket,sys
try:
    socket.create_connection(("1.1.1.1",443),timeout=3); print("EXTERNAL_OK"); sys.exit(1)
except OSError: pass
s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(1); print("ISOLATED"); sys.exit(0)'
detect_netmode() {
  local sif="$1" m
  for m in a b c; do
    if run_isolated_mode "$m" "$sif" -- python3 -c "$_net_probe" 2>/dev/null | grep -q ISOLATED; then
      echo "$m" | tee "$NETMODE_FILE"; return 0
    fi
  done
  return 1
}
run_isolated_mode() {
  local m="$1" sif="$2"; shift 3
  case "$m" in
    a) "$APPTAINER" exec --containall --cleanenv --nv --net --network none "${EXTRA_BINDS[@]}" "$sif" "$@" ;;
    b) "$APPTAINER" exec --containall --cleanenv --nv --fakeroot --net --network none "${EXTRA_BINDS[@]}" "$sif" "$@" ;;
    c) unshare -rn sh -c 'ip link set lo up 2>/dev/null || true; exec "$@"' _ \
         "$APPTAINER" exec --containall --cleanenv --nv "${EXTRA_BINDS[@]}" "$sif" "$@" ;;
  esac
}
EXTRA_BINDS=()
run_isolated() {  # run_isolated <sif> -- <cmd...>
  local sif="$1" m
  m="$(cat "$NETMODE_FILE" 2>/dev/null || true)"
  [[ -n "$m" ]] || m="$(detect_netmode "$sif")" || die "ネットワーク遮断の方法がどれも使えません（§4.4 a〜c）"
  run_isolated_mode "$m" "$@"
}
