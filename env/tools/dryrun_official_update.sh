#!/usr/bin/env bash
# 公式配布当日の流れのドライラン（要件定義書 §8）。使い捨てのリポジトリだけを使い、正式なリポジトリには何も残さない。
#   bash env/tools/dryrun_official_update.sh [--skip-build]
# 手順:
#   1. 模擬の公式リポジトリを作る（版を2項目ずらした requirements.txt、Singularity 定義、仮の gateway / EnvClient）
#   2. 差分確認で、ずれを全件検出できるか
#   3. 使い捨てのリポジトリ（このリポジトリの clone）で、版の反映・評価コードのハッシュ一覧作成・コミット
#   4. 基盤イメージを再ビルド（build_base.sh。公式コードの取得とハッシュ照合を含む）
#   5. 使い捨てのリポジトリにタグを付ける
set -euo pipefail
ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
SKIP_BUILD=""; [[ "${1:-}" == "--skip-build" ]] && SKIP_BUILD=1
D="$(mktemp -d "${TMPDIR:-/tmp}/capx-dryrun.XXXXXX")"
echo "dry-run dir: $D"
pass=0; fail=0
check() { if eval "$2"; then echo "  PASS: $1"; pass=$((pass+1)); else echo "  FAIL: $1"; fail=$((fail+1)); fi; }

echo "== 1. 模擬の公式リポジトリ"
OFF="$D/official"; mkdir -p "$OFF/capx_eval/gateway" "$OFF/capx_eval/envclient"
# 本環境のロックから2項目の版をずらす
rs="$(grep -E '^robosuite==' "$ROOT/env/requirements/robosuite.txt" | cut -d= -f3 | tr -d ' \\')"
np="$(grep -E '^numpy==' "$ROOT/env/requirements/robosuite.txt" | cut -d= -f3 | tr -d ' \\')"
cat > "$OFF/requirements.txt" <<EOF
robosuite==1.5.1
numpy==2.1.3
scipy>=1.10
EOF
printf 'Bootstrap: docker\nFrom: nvcr.io/nvidia/vllm:26.05.post1-py3\n' > "$OFF/eval.def"
echo 'def serve(): return "gateway"' > "$OFF/capx_eval/gateway/server.py"
echo 'class EnvClient: pass'         > "$OFF/capx_eval/envclient/client.py"
git -C "$OFF" init -q -b main && git -C "$OFF" -c user.email=dryrun@example.invalid -c user.name=dryrun add -A \
  && git -C "$OFF" -c user.email=dryrun@example.invalid -c user.name=dryrun commit -qm "mock official"
OFF_COMMIT="$(git -C "$OFF" rev-parse HEAD)"
echo "  ours: robosuite=$rs numpy=$np / official: robosuite=1.5.1 numpy=2.1.3"

echo "== 2. 差分確認"
python3 "$ROOT/env/tools/diff_versions.py" --official "$OFF" --ours "$ROOT" --format tsv > "$D/diff.tsv" 2> "$D/diff.log" || true
cat "$D/diff.tsv" | awk -F'\t' '$4!="本環境のみ"' | sed 's/^/    /'
check "robosuite の不一致を検出" "awk -F'\t' '\$1==\"pip:robosuite\" && \$4==\"不一致\"' '$D/diff.tsv' | grep -q ."
check "numpy の不一致を検出"     "awk -F'\t' '\$1==\"pip:numpy\" && \$4==\"不一致\"' '$D/diff.tsv' | grep -q ."
check "公式のみの項目（scipy の条件）を検出" "awk -F'\t' '\$1==\"pip:scipy\"' '$D/diff.tsv' | grep -q ."
check "ベースイメージを比較"     "awk -F'\t' '\$1==\"base_image\"' '$D/diff.tsv' | grep -q ."

echo "== 3. 使い捨てのリポジトリで反映"
TR="$D/throwaway"; git clone -q "$ROOT" "$TR"
git -C "$TR" config user.email "dryrun@users.noreply.github.com"; git -C "$TR" config user.name dryrun
sed -i "s|^OFFICIAL_REPO_URL=.*|OFFICIAL_REPO_URL=$OFF|; s|^OFFICIAL_COMMIT=.*|OFFICIAL_COMMIT=$OFF_COMMIT|" "$TR/env/versions.submission.env"
sed -i 's/^robosuite==.*/robosuite==1.5.1/' "$TR/env/requirements/robosuite.in"
(cd "$TR" && uv pip compile -q --python-version 3.12 --python-platform x86_64-manylinux_2_28 --generate-hashes \
   env/requirements/robosuite.in -o env/requirements/robosuite.txt)
python3 "$TR/env/tools/eval_code_hash.py" make --root "$OFF" --paths capx_eval/gateway capx_eval/envclient > "$TR/env/eval_code.sha256"
git -C "$TR" add -A && git -C "$TR" commit -qm "dry-run: follow mock official"
TRC="$(git -C "$TR" rev-parse HEAD)"
check "反映後は robosuite が一致" "python3 '$TR/env/tools/diff_versions.py' --official '$OFF' --ours '$TR' --format tsv 2>/dev/null | awk -F'\t' '\$1==\"pip:robosuite\" && \$4==\"一致\"' | grep -q ."
check "評価コードのハッシュ照合（改変なし）" "python3 '$TR/env/tools/eval_code_hash.py' verify --root '$OFF' --list '$TR/env/eval_code.sha256' >/dev/null"
cp -r "$OFF" "$D/official_tampered"; echo '# tampered' >> "$D/official_tampered/capx_eval/envclient/client.py"
check "評価コードの改変を検出" "! python3 '$TR/env/tools/eval_code_hash.py' verify --root '$D/official_tampered' --list '$TR/env/eval_code.sha256' >/dev/null"

if [[ -z "$SKIP_BUILD" ]]; then
  echo "== 4. 基盤イメージの再ビルド（数十分かかる）"
  TAG="base-$(date -u +%Y%m%d).99"
  if CAPX_DATA="$D/data" bash "$TR/env/jobs/build_base.sh" --commit "$TRC" --source-dir "$TR" --tag "$TAG" --out "$D/build" > "$D/build.out" 2> "$D/build.err"; then
    LINE="$(tail -1 "$D/build.out")"; echo "  images.lock line: $LINE"
    check "ビルド成功・SHA-256 を記録" "[[ \"\$(echo '$LINE' | wc -w)\" -eq 4 ]]"
    check "ビルド時に評価コードを照合" "grep -q 'ng=0' \"\$(ls -d $D/data/records/*/*-base | head -1)/eval_code_verify.txt\""
    check "公式コードがイメージ内にある" "apptainer exec '$D/build/$TAG.sif' cat /opt/official/.capx_commit | grep -q '$OFF_COMMIT'"
    echo "$LINE" >> "$TR/env/images.lock"; git -C "$TR" commit -qam "dry-run: images.lock"
  else
    echo "  ビルド失敗: $D/build.err"; tail -20 "$D/build.err"; fail=$((fail+1))
  fi
fi

echo "== 5. 使い捨てのリポジトリにタグ"
git -C "$TR" tag -a "base-$(date -u +%Y%m%d).99" -m "dry-run" && check "タグ付け" "git -C '$TR' tag | grep -q '.99'"
check "正式なリポジトリにはタグを付けていない" "! git -C '$ROOT' tag | grep -q '\.99$'"

echo
echo "dry-run: pass=$pass fail=$fail（作業ディレクトリ: $D）"
[[ $fail -eq 0 ]]
