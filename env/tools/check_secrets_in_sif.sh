#!/usr/bin/env bash
# イメージにトークン等が残っていないかを確かめる（提出・公開で漏れるのを防ぐ）。
#   check_secrets_in_sif.sh <sif>
# 対象: 定義ファイル（イメージに保存されたもの）、環境変数、/opt・/root・/etc・/home 配下のテキスト。
set -euo pipefail
SIF="$1"; APP="${APPTAINER:-apptainer}"
PAT='(ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|gho_[A-Za-z0-9]{20,}|hf_[A-Za-z0-9]{30,}|x-access-token:[A-Za-z0-9_]{20,}@|-----BEGIN [A-Z ]*PRIVATE KEY-----)'
found=0
for what in --deffile --environment --runscript; do
  if "$APP" inspect "$what" "$SIF" 2>/dev/null | grep -Eq "$PAT"; then echo "NG: inspect $what にトークンらしき文字列"; found=1; fi
done
if "$APP" exec --containall "$SIF" sh -c "grep -rIEl '$PAT' /opt /root /etc /home 2>/dev/null | grep -v -e '/site-packages/' -e '/dist-packages/' -e '/uv-python/' | head -20" | grep -q .; then
  echo "NG: イメージ内のファイルにトークンらしき文字列"
  "$APP" exec --containall "$SIF" sh -c "grep -rIEl '$PAT' /opt /root /etc /home 2>/dev/null | grep -v -e '/site-packages/' -e '/dist-packages/' -e '/uv-python/' | head -20"
  found=1
fi
[[ $found -eq 0 ]] && echo "OK: トークンらしき文字列は見つかりませんでした"
exit $found
