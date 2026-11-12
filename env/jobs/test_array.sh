#!/usr/bin/env bash
#SBATCH --job-name=capx-tests
#SBATCH --gpus=1
#SBATCH --time=01:00:00
# 複数のテストを Slurm の job array でまとめて流す（誰でも実行できる）。
# テストは「GPU 1 枚＝テスト用」の運用に合わせ、同時実行数を絞って投入する（例: %1）。
#
#   sbatch --array=0-<N-1>%1 env/jobs/test_array.sh --sif <agent.sif> --commit <sha> --list <tests.tsv>
#   （ローカル PC では SLURM_ARRAY_TASK_ID=<i> bash env/jobs/test_array.sh ...）
#
# tests.tsv は 1 行 1 テスト: <名前>\t<smoke_test.sh への追加引数>
#   例: robosuite-4x2\t--sim robosuite --trials 4 --parallel 2
#       libero-2x2\t--sim libero --trials 2 --parallel 2
# 各テストは smoke_test.sh（ネットワーク遮断・重みは読み取り専用マウント）で実行し、記録は実行ごとに別ディレクトリに残る。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/common.sh"
SIF="" COMMIT="" LIST="" SRCDIR=""
while [[ $# -gt 0 ]]; do case "$1" in
  --sif) SIF="$2"; shift 2;; --commit) COMMIT="$2"; shift 2;; --list) LIST="$2"; shift 2;;
  --source-dir) SRCDIR="$2"; shift 2;; *) die "不明な引数: $1";; esac; done
[[ -f "$SIF" && -n "$COMMIT" && -f "$LIST" ]] || die "--sif・--commit・--list は必須です"
IDX="${SLURM_ARRAY_TASK_ID:?SLURM_ARRAY_TASK_ID がありません（sbatch --array で投入するか、手元では環境変数で指定）}"
line="$(grep -v -e '^#' -e '^\s*$' "$LIST" | sed -n "$((IDX + 1))p")"
[[ -n "$line" ]] || die "テスト一覧に $IDX 番目がありません"
name="${line%%$'\t'*}"; args="${line#*$'\t'}"
note "test[$IDX] $name: $args"
# shellcheck disable=SC2086
bash "$HERE/smoke_test.sh" --sif "$SIF" --commit "$COMMIT" ${SRCDIR:+--source-dir "$SRCDIR"} $args
