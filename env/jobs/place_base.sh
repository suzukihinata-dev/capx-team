#!/usr/bin/env bash
# images.lock の PR がマージされた後に、base.sif を共有の images/ に配置する（環境担当が実行）。
#   place_base.sh --sif <path> --lock <env/images.lock> [--images-dir DIR]
# 配置の前に SHA-256 とサイズを images.lock の記録と照合する（全体の計算は配置時に1回）。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/common.sh"
SIF="" LOCK="" IMAGES="$CAPX_DATA/images"
while [[ $# -gt 0 ]]; do case "$1" in
  --sif) SIF="$2"; shift 2;; --lock) LOCK="$2"; shift 2;; --images-dir) IMAGES="$2"; shift 2;;
  *) die "不明な引数: $1";; esac; done
[[ -f "$SIF" && -f "$LOCK" ]] || die "--sif と --lock を指定してください"
TAG="$(basename "$SIF" .sif)"; TAG="${TAG#base-}"
line="$(grep -E "^$TAG " "$LOCK" || true)"; [[ -n "$line" ]] || die "images.lock に $TAG がありません（PR のマージ前に配置しない）"
read -r _ want_sha want_size _ <<<"$line"
[[ "$(stat -c %s "$SIF")" == "$want_size" ]] || die "サイズが images.lock と一致しません"
[[ "$(sha256sum "$SIF" | cut -d' ' -f1)" == "$want_sha" ]] || die "SHA-256 が images.lock と一致しません"
mkdir -p "$IMAGES"; dest="$IMAGES/base-$TAG.sif"
[[ -e "$dest" ]] && die "既に配置済み: $dest"
cp "$SIF" "$dest.partial" && chmod a-w "$dest.partial" && mv "$dest.partial" "$dest"
note "配置しました: $dest（Slack の Agent 班チャンネルへ通知してください）"
