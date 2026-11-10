#!/usr/bin/env bash
# 軽量検査（PR ごと。鍵・GPU 不要）。CI が整うまでは手元で実行し、結果を PR に貼る。
#   bash env/tools/lightweight_checks.sh
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
FAIL=0
step() { echo "== $*"; }
ng()   { echo "  NG: $*"; FAIL=1; }
ok()   { echo "  OK: $*"; }

step "1. シェルスクリプトの構文"
for f in env/*.sh env/jobs/*.sh env/tools/*.sh; do bash -n "$f" || ng "$f"; done && ok "bash -n"
if command -v shellcheck >/dev/null; then shellcheck -S warning env/*.sh env/jobs/*.sh env/tools/*.sh && ok shellcheck || ng shellcheck; else echo "  (shellcheck なし: スキップ)"; fi

step "2. Python の構文と単体テスト"
python3 -m py_compile env/tools/*.py env/smoke/*.py agent/capx_agent/*.py && ok py_compile || ng py_compile
(cd agent && python3 -m unittest -q discover -s tests -t . 2>&1 | tail -1) | grep -q '^OK' && ok unittest || ng unittest

step "3. ロックファイル"
python3 env/tools/models.py check --lock agent/models.lock >/dev/null && ok models.lock || ng models.lock
for f in env/requirements/*.in; do t="${f%.in}.txt"; [[ -s "$t" ]] && grep -q -- '--hash=sha256:' "$t" && ok "$t" || ng "$t がないかハッシュなし"; done
[[ -s agent/uv.lock ]] && ok agent/uv.lock || ng "agent/uv.lock がない"
grep -Eq '^BASE_IMAGE_DIGEST=sha256:[0-9a-f]{64}$' env/versions.submission.env && ok "ベースは digest で固定" || ng "BASE_IMAGE_DIGEST"

step "4. 手順の版番号"
grep -Eq '^JOB_PROTOCOL_VERSION=[0-9]+$' env/versions.submission.env && ok JOB_PROTOCOL_VERSION || ng JOB_PROTOCOL_VERSION
base="$(git merge-base HEAD origin/main 2>/dev/null || true)"
if [[ -n "$base" ]] && ! git diff --quiet "$base" -- env/jobs/; then
  git diff "$base" -- env/versions.submission.env | grep -q '^+JOB_PROTOCOL_VERSION=' \
    && ok "env/jobs/ の変更に合わせて版番号を上げた" || ng "env/jobs/ を変えたのに JOB_PROTOCOL_VERSION を上げていない"
fi

step "5. 秘密情報・入れてはいけないものの混入"
PAT='(ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|hf_[A-Za-z0-9]{30,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)'
if git grep -IEn "$PAT" -- . ':!env/tools/*' >/dev/null; then ng "トークン・秘密鍵らしき文字列"; git grep -IEn "$PAT" -- . ':!env/tools/*' | cut -c1-120; else ok "トークン・秘密鍵なし"; fi
big="$(git ls-files -z | xargs -0 -I{} sh -c 'test $(stat -c %s "{}" 2>/dev/null || stat -f %z "{}") -gt 5000000 && echo "{}"' || true)"
[[ -z "$big" ]] && ok "5MB を超えるファイルなし" || ng "大きなファイル: $big"
git ls-files | grep -Eiq '\.(sif|safetensors|bin|pt|pth|ckpt|gguf)$' && ng "イメージ・重みのファイルがリポジトリにある" || ok "イメージ・重みのファイルなし"
bad_mail="$(git log --format='%ae%n%ce' | sort -u | grep -v 'users.noreply.github.com$' || true)"
[[ -z "$bad_mail" ]] && ok "コミットのメールは非公開アドレスのみ" || ng "非公開アドレス以外のメール: $bad_mail"

echo
[[ $FAIL -eq 0 ]] && echo "軽量検査: 合格" || echo "軽量検査: 不合格"
exit $FAIL
