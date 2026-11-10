#!/usr/bin/env bash
# ビルド済みの base.sif から、apt パッケージの版を固定する env/apt.lock を作る。
#   make_apt_lock.sh <base.sif> > env/apt.lock
# 次回以降のビルドは apt.lock の版で入れる（版の固定）。PR で反映する。
set -euo pipefail
echo "# generated from $(basename "$1") on $(date -u +%Y-%m-%d)"
"${APPTAINER:-apptainer}" exec "$1" cat /opt/capx/apt.installed
