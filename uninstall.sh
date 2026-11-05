#!/data/data/com.termux/files/usr/bin/bash
# W8BDCR Hermes - uninstaller (own code)
# Removes, in order:
#   - hermes-agent source + venv inside the container
#   - the ~/.local/bin/hermes launcher + the PATH line in .bashrc
#   - the ~/.local/bin/hermes-start.sh + hermes-fix.sh helpers
#   - the Termux-level `hermes`, `hermes-start` + `hermes-fix` wrappers
#   - (optional, only if you say yes) the whole container
#   - the project folder this script was run from
# Nothing is deleted without confirmation.
set -uo pipefail

export TERM="${TERM:-xterm}"
export DEBIAN_FRONTEND=noninteractive
export TZ=UTC

echo "=============================================="
echo "  W8BDCR Hermes - Uninstaller"
echo "=============================================="
echo ""

termux-wake-lock 2>/dev/null || true

# Detect the container the installer used, same check as install.
DISTRO="ubuntu"
ROOTFS="${PREFIX:-/data/data/com.termux/files/usr}/var/lib/proot-distro"
container_present() {
    proot-distro list 2>/dev/null | grep -qiE "^[[:space:]]*\\*?[[:space:]]*$1([[:space:]]|$)" && return 0
    [ -d "$ROOTFS/installed-rootfs/$1" ] && return 0
    [ -f "$ROOTFS/containers/$1/manifest.json" ] && [ -d "$ROOTFS/containers/$1/rootfs" ] && return 0
    return 1
}
for candidate in ubuntu ubuntu-hermes hermes2 hermes3 hermes4 hermes; do
    if container_present "$candidate"; then DISTRO="$candidate"; break; fi
done
echo "Target container: $DISTRO"
echo ""

echo "This will DELETE Hermes Agent inside container '$DISTRO'."
read -r -p "Type 'yes' to continue, anything else to cancel: " ANSWER < /dev/tty
if [ "$ANSWER" != "yes" ]; then
    echo "Cancelled. Nothing was removed."
    exit 0
fi
echo ""

# 1) Inside the container: agent, launcher, PATH line.
if container_present "$DISTRO"; then
    echo "Removing Hermes Agent inside $DISTRO..."
    proot-distro login "$DISTRO" -- bash -c '
        rm -rf "$HOME/hermes-agent"
        rm -f  "$HOME/.local/bin/hermes" "$HOME/.local/bin/hermes-start.sh" "$HOME/.local/bin/hermes-fix.sh"
        rmdir  "$HOME/.local/bin" 2>/dev/null || true
        sed -i '\''\#export PATH="$HOME/.local/bin:$PATH"#d'\'' "$HOME/.bashrc" 2>/dev/null || true
    '
fi

# Termux-level wrapper.
rm -f "${PREFIX:-/data/data/com.termux/files/usr}/bin/hermes" "${PREFIX:-/data/data/com.termux/files/usr}/bin/hermes-start" "${PREFIX:-/data/data/com.termux/files/usr}/bin/hermes-fix" 2>/dev/null || true

# 2) Optional: whole container.
echo ""
read -r -p "Remove the whole container '$DISTRO' too? (y/N): " RMX < /dev/tty
if [ "$RMX" = "y" ] || [ "$RMX" = "Y" ]; then
    if command -v proot-distro >/dev/null 2>&1; then
        echo "Removing container $DISTRO..."
        proot-distro remove "$DISTRO" 2>&1 || proot-distro uninstall "$DISTRO" 2>&1 || true
    else
        echo "proot-distro not installed - deleting rootfs dir directly..."
        rm -rf "$ROOTFS/containers/$DISTRO" "$ROOTFS/installed-rootfs/$DISTRO"
    fi
else
    echo "Container kept."
fi

# 3) Project folder cleanup.
REPO_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
if [ -n "$REPO_DIR" ] && [ -e "$REPO_DIR/uninstall.sh" ]; then
    echo "Removing project folder: $REPO_DIR"
    rm -rf "$REPO_DIR"
fi
rm -f "$0" 2>/dev/null || true

echo ""
echo "W8BDCR Hermes uninstalled successfully."
echo "Termux itself is untouched."
