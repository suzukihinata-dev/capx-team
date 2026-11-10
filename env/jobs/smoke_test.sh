#!/usr/bin/env bash
#SBATCH --job-name=capx-smoke
#SBATCH --gpus=1
#SBATCH --time=01:00:00
# 提出イメージのスモークテスト（誰でも実行できる）。
#   smoke_test.sh --sif agent.sif --commit <sha> [--trials N --parallel P --sim none|robosuite|libero] [--no-server]
# - バインドなし（エージェントコードを差し込まない）・--containall・ネットワーク遮断で動かす
# - 重みは models.lock に従い、評価時と同じ path に読み取り専用でマウントする
# - %labels の元コミットと、イメージ内のコードが元コミットと一致することを確かめる
# - トークンがイメージに残っていないことを確かめる
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/common.sh"
SIF="" COMMIT="" TRIALS=4 PAR=2 SIM=none NOSERVER="" SRCDIR=""
while [[ $# -gt 0 ]]; do case "$1" in
  --sif) SIF="$2"; shift 2;; --commit) COMMIT="$2"; shift 2;; --trials) TRIALS="$2"; shift 2;;
  --parallel) PAR="$2"; shift 2;; --sim) SIM="$2"; shift 2;; --no-server) NOSERVER=--no-server; shift;;
  --source-dir) SRCDIR="$2"; shift 2;; *) die "不明な引数: $1";; esac; done
[[ -f "$SIF" && -n "$COMMIT" ]] || die "--sif と --commit は必須です"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/capx-smoke.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
FULL="$(prepare_source "$COMMIT" "$WORK/src" "$SRCDIR")"
REC="$(make_record_dir "$FULL" smoke)"
RESULT=0

# 1) 出自（%labels）
label_commit="$("$APPTAINER" inspect --labels "$SIF" | awk -F': ' '/org.capx.source_commit/{print $2}')"
if [[ "$label_commit" == "$FULL" ]]; then echo "labels: OK" >>"$REC/checks.txt"; else echo "labels: NG ($label_commit != $FULL)" >>"$REC/checks.txt"; RESULT=1; fi

# 2) イメージ内のコードと元コミットの一致
if python3 "$HERE/../tools/sif_code_check.py" --sif "$SIF" --src "$WORK/src/agent" --inside /opt/capx/agent > "$REC/code_check.txt"; then
  echo "code: OK" >>"$REC/checks.txt"; else echo "code: NG" >>"$REC/checks.txt"; RESULT=1; fi

# 3) トークンの残存
if bash "$HERE/../tools/check_secrets_in_sif.sh" "$SIF" > "$REC/secrets_check.txt" 2>&1; then
  echo "secrets: OK" >>"$REC/checks.txt"; else echo "secrets: NG" >>"$REC/checks.txt"; RESULT=1; fi

# 4) 実行（ネットワーク遮断・重みは読み取り専用マウント）
mapfile -t BINDS < <(python3 "$HERE/../tools/models.py" binds --lock "$WORK/src/agent/models.lock" --cache "$CAPX_DATA/models")
EXTRA_BINDS=("${BINDS[@]}")
note "run: trials=$TRIALS parallel=$PAR sim=$SIM $NOSERVER"
t0=$(date +%s)
if run_isolated "$SIF" -- /opt/venvs/agent/bin/python -m capx_agent.runner --trials "$TRIALS" --parallel "$PAR" \
     --sim "$SIM" $NOSERVER > "$REC/runner.json" 2> "$REC/runner.stderr"; then
  echo "runner: OK" >>"$REC/checks.txt"; else echo "runner: NG" >>"$REC/checks.txt"; RESULT=1; fi
echo "netmode: $(cat "$NETMODE_FILE")" >>"$REC/checks.txt"
write_meta "$REC" kind=smoke commit="$FULL" sif="$SIF" trials="$TRIALS" parallel="$PAR" sim="$SIM" \
  seconds="$(( $(date +%s) - t0 ))" result="$RESULT"
seal_record "$REC"
cat "$REC/checks.txt"
echo "record: $REC"
exit "$RESULT"
