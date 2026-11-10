#!/usr/bin/env bash
# ローカル開発用 Linux PC のホスト基盤を整える（冪等）。
#   sudo bash env/install-host.sh           インストールと確認
#   bash env/install-host.sh --check        確認だけ（sudo 不要・変更しない）
#
# 方針:
# - NVIDIA ドライバと Git は確認だけで、入れ替えない。
# - Apptainer は公式リリースの .deb を SHA-256 で照合してから入れる。
# - Ubuntu 24.04 以降の AppArmor による user namespace 制限は、Apptainer 用のプロファイルで対応する
#   （制限そのものを全体で無効にはしない）。
# - uv は実行ユーザー（sudo の呼び出し元）の ~/.local/bin に入れる。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/versions.local.env"

MODE=install
[[ "${1:-}" == "--check" ]] && MODE=check

TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
FAIL=0
ok()   { printf '  [OK]   %s\n' "$*"; }
ng()   { printf '  [NG]   %s\n' "$*"; FAIL=1; }
info() { printf '  [..]   %s\n' "$*"; }

ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }

echo "== 1. NVIDIA ドライバ（確認のみ）"
if command -v nvidia-smi >/dev/null; then
  drv="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)"
  if ver_ge "$drv" "$NVIDIA_DRIVER_MIN"; then ok "driver $drv (>= $NVIDIA_DRIVER_MIN)"; else ng "driver $drv < $NVIDIA_DRIVER_MIN（入れ替えはしない。版の選定を見直す）"; fi
  nvidia-smi --query-gpu=name,memory.total,compute_cap --format=csv,noheader | sed 's/^/         /'
else
  ng "nvidia-smi が見つからない（ドライバは本スクリプトでは入れない）"
fi

echo "== 2. Git（確認のみ）"
command -v git >/dev/null && ok "$(git --version)" || ng "git が見つからない"

echo "== 3. Apptainer $APPTAINER_VERSION"
have_app=""
if command -v apptainer >/dev/null; then have_app="$(apptainer --version | awk '{print $NF}')"; fi
if [[ "$have_app" == "$APPTAINER_VERSION" ]]; then
  ok "apptainer $have_app は導入済み"
elif [[ "$MODE" == check ]]; then
  ng "apptainer ${have_app:-未導入}（期待: $APPTAINER_VERSION）"
else
  [[ $EUID -eq 0 ]] || { echo "インストールには sudo が必要です: sudo bash $0" >&2; exit 1; }
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  info "ダウンロード: $APPTAINER_DEB_URL"
  curl -fsSL -o "$tmp/$APPTAINER_DEB" "$APPTAINER_DEB_URL"
  echo "$APPTAINER_DEB_SHA256  $tmp/$APPTAINER_DEB" | sha256sum -c - >/dev/null || { ng "SHA-256 不一致。中止"; exit 1; }
  ok "SHA-256 一致"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$tmp/$APPTAINER_DEB" uidmap
  ok "apptainer $(apptainer --version | awk '{print $NF}') を導入"
fi

echo "== 4. AppArmor（権限なしの user namespace）"
restrict="$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)"
info "kernel.apparmor_restrict_unprivileged_userns=$restrict"
PROFILE=/etc/apparmor.d/apptainer
if [[ "$restrict" != 1 ]]; then
  ok "制限なし（プロファイル不要）"
elif [[ -f "$PROFILE" ]]; then
  ok "プロファイルあり: $PROFILE"
  if [[ "$MODE" == install ]]; then apparmor_parser -r "$PROFILE" && ok "プロファイルを再読み込み"; fi
elif [[ "$MODE" == check ]]; then
  ng "プロファイルなし: $PROFILE"
else
  # .deb にプロファイルが含まれない場合に限り、Apptainer の実行ファイルだけに userns を許可する。
  cat > "$PROFILE" <<'EOF'
# Managed by capx env/install-host.sh
abi <abi/4.0>,
include <tunables/global>
profile apptainer /usr/libexec/apptainer/bin/starter{,-suid} flags=(unconfined) {
  userns,
  include if exists <local/apptainer>
}
EOF
  apparmor_parser -r "$PROFILE" && ok "プロファイルを作成して読み込み: $PROFILE"
fi

echo "== 5. --fakeroot 用の subuid / subgid（$TARGET_USER）"
if grep -q "^$TARGET_USER:" /etc/subuid && grep -q "^$TARGET_USER:" /etc/subgid; then ok "設定済み"; else ng "未設定（sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $TARGET_USER）"; fi

echo "== 6. uv $UV_VERSION（$TARGET_USER の ~/.local/bin）"
UVBIN="$TARGET_HOME/.local/bin/uv"
have_uv=""; [[ -x "$UVBIN" ]] && have_uv="$("$UVBIN" --version | awk '{print $2}')"
if [[ "$have_uv" == "$UV_VERSION" ]]; then
  ok "uv $have_uv は導入済み"
elif [[ "$MODE" == check ]]; then
  ng "uv ${have_uv:-未導入}（期待: $UV_VERSION）"
else
  tmpu="$(mktemp -d)"
  curl -fsSL -o "$tmpu/uv.tgz" "$UV_TARBALL_URL"
  echo "$UV_TARBALL_SHA256  $tmpu/uv.tgz" | sha256sum -c - >/dev/null || { ng "uv の SHA-256 不一致。中止"; exit 1; }
  tar -xzf "$tmpu/uv.tgz" -C "$tmpu"
  install -d -o "$TARGET_USER" -g "$TARGET_USER" "$TARGET_HOME/.local/bin"
  install -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$tmpu"/uv-x86_64-unknown-linux-gnu/uv "$tmpu"/uv-x86_64-unknown-linux-gnu/uvx "$TARGET_HOME/.local/bin/"
  rm -rf "$tmpu"
  ok "uv $("$UVBIN" --version | awk '{print $2}') を導入"
fi

echo "== 7. 権限の強いグループ（docker / lxd / libvirt）に班長以外がいないか"
for g in docker lxd libvirt sudo; do
  members="$(getent group "$g" | cut -d: -f4)"
  extra="$(tr ',' '\n' <<<"$members" | grep -v -x -e '' -e "$TARGET_USER" || true)"
  if [[ -z "$extra" ]]; then ok "$g: ${members:-（空）}"; else ng "$g に班長以外のユーザー: $extra"; fi
done

echo
if [[ $FAIL -eq 0 ]]; then echo "結果: すべて OK（$MODE）"; else echo "結果: NG あり（$MODE）"; exit 1; fi
