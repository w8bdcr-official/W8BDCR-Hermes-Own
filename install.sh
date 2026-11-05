#!/data/data/com.termux/files/usr/bin/bash
# W8BDCR Hermes - own installer for Termux
# Written by W8BDCR, from scratch. Install process, step for step,
# exactly like a complete Termux Hermes install:
#   Termux packages -> Ubuntu container (reused if present) ->
#   Ubuntu packages -> compatible Python -> Hermes Agent ->
#   Ubuntu launcher -> Termux-level `hermes` command.
# Usage in Termux:
#   curl -fsSL https://raw.githubusercontent.com/w8bdcr-official/W8BDCR-Hermes-Own/main/install.sh | bash

set -euo pipefail

export TERM="${TERM:-xterm}"
export DEBIAN_FRONTEND=noninteractive
export TZ=UTC

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
RESET='\033[0m'

say() { echo -e "${GREEN}$1${RESET}"; }
warn() { echo -e "${YELLOW}$1${RESET}"; }

: >/dev/tty 2>/dev/null && clear 2>/dev/null || true
say "=============================================="
say "  W8BDCR Hermes - Termux Installer"
say "=============================================="
echo ""

# Keep Termux alive during the long install.
termux-wake-lock 2>/dev/null || true

# --- Step 1: Termux packages, with repair + retry on failure ---
warn "Step 1 - Updating Termux packages..."
if ! yes | pkg update -y 2>&1; then
    warn "pkg update had an error - trying apt repair, then retrying..."
    apt --fix-broken install -y 2>&1 || true
    yes | pkg update -y 2>&1 || true
fi
warn "Upgrading Termux packages..."
yes | pkg upgrade -y 2>&1 || true

warn "Step 2 - Preparing container tool..."
pkg install proot-distro -y 2>&1 || true

# --- Step 2: Container - reuse any existing Hermes/Ubuntu container ---
# proot-distro has changed its on-disk layout over versions, so check
# all three signals: the list output, the old rootfs dir, and the new
# containers dir with a manifest + rootfs.
DISTRO="ubuntu"
ROOTFS="${PREFIX:-/data/data/com.termux/files/usr}/var/lib/proot-distro"
container_present() {
    proot-distro list 2>/dev/null | grep -qiE "^[[:space:]]*\\*?[[:space:]]*$1([[:space:]]|$)" && return 0
    [ -d "$ROOTFS/installed-rootfs/$1" ] && return 0
    [ -f "$ROOTFS/containers/$1/manifest.json" ] && [ -d "$ROOTFS/containers/$1/rootfs" ] && return 0
    return 1
}
for candidate in ubuntu ubuntu-hermes hermes2 hermes3 hermes4 hermes; do
    if container_present "$candidate"; then
        DISTRO="$candidate"
        say "Reusing existing container: $candidate"
        break
    fi
done
if [ "$DISTRO" = "ubuntu" ] && ! container_present "ubuntu"; then
    warn "Installing Ubuntu container (a few minutes)..."
    proot-distro install ubuntu 2>&1 || warn "Container install reported an issue - continuing with the existing one."
    say "Ubuntu container ready."
fi

# --- Step 3+4: Everything inside Ubuntu, in one inner script ---
INNER="$(mktemp)"
trap 'rm -f "$INNER"' EXIT

cat > "$INNER" << 'INNER_END'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export TZ=UTC

echo "Step 3 - Updating Ubuntu packages..."
apt-get update -qq
apt-get upgrade -y -o Dpkg::Options::="--force-confold" >/dev/null 2>&1 || true

echo "Installing Ubuntu dependencies..."
apt-get install -y -o Dpkg::Options::="--force-confold" \
    python3 python3-pip python3-venv python3-dev python-is-python3 \
    git curl wget build-essential \
    nodejs npm \
    libffi-dev libssl-dev pkg-config \
    ca-certificates >/dev/null 2>&1 || true

# Hermes Agent's core dependencies are pinned to Python >= 3.14
# (upstream pyproject markers). A 3.11-3.13 venv installs the package
# with ZERO dependencies, so `hermes setup` then crashes module by
# module (ruamel, dotenv, ...). Use Python 3.14 or newer; fetch 3.14
# with uv when the system Python is older.
PY="python3"
if ! "$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 14) else 1)' 2>/dev/null; then
    echo "System Python is too old for Hermes Agent - getting Python 3.14 with uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1 || true
    export PATH="$HOME/.local/bin:$PATH"
    command -v uv >/dev/null 2>&1 || python3 -m pip install uv >/dev/null 2>&1 || true
    uv python install 3.14 >/dev/null 2>&1 || true
    PY="$(uv python find 3.14 2>/dev/null || echo python3)"
fi
echo "Using Python: $("$PY" --version 2>&1)"

# Get Hermes Agent (upstream open-source project), or update it.
if [ -d "$HOME/hermes-agent/.git" ]; then
    echo "Updating existing hermes-agent copy..."
    cd "$HOME/hermes-agent"
    git fetch origin 2>/dev/null || true
    git checkout main 2>/dev/null || git checkout master 2>/dev/null || true
    git reset --hard origin/main 2>/dev/null || git reset --hard origin/master 2>/dev/null || true
else
    echo "Downloading Hermes Agent..."
    rm -rf "$HOME/hermes-agent"
    git clone --depth 1 --recurse-submodules --shallow-submodules \
        https://github.com/NousResearch/hermes-agent.git "$HOME/hermes-agent"
    cd "$HOME/hermes-agent"
fi

# Fresh virtual environment.
rm -rf venv
if command -v uv >/dev/null 2>&1; then
    uv venv --python "$PY" venv
else
    "$PY" -m venv venv
fi
source venv/bin/activate

# pip helper: uv pip when uv is present (avoids PEP-668 blocks),
# otherwise the venv's own pip.
run_pip() {
    if command -v uv >/dev/null 2>&1; then
        uv pip "$@"
    else
        venv/bin/python -m pip --break-system-packages "$@" \
            || venv/bin/python -m pip "$@"
    fi
}

# uv is required: only `uv pip --override` can resolve the upstream
# Pillow conflict below (plain pip has no override mechanism).
if ! command -v uv >/dev/null 2>&1; then
    echo "Installing uv (needed to resolve a dependency conflict)..."
    curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1 || true
    export PATH="$HOME/.local/bin:$PATH"
    command -v uv >/dev/null 2>&1 || python3 -m pip install uv >/dev/null 2>&1 || true
fi

echo "Upgrading pip, setuptools, wheel..."
run_pip install --upgrade pip setuptools wheel >/dev/null 2>&1 || true

echo "Installing Hermes Agent (this can take 5-10 minutes)..."
# Upstream is currently unresolvable as-is: core pins Pillow==13.0.0
# but browser-harness==0.1.13 (also core) requires pillow==12.3.0.
# Override browser-harness's pin to Pillow 13 (API-compatible here).
# Only uv understands --override, so skip the flag if uv is missing.
printf 'pillow==13.0.0\n' > overrides.txt
OVERRIDE_ARGS=()
if command -v uv >/dev/null 2>&1; then OVERRIDE_ARGS=(--override overrides.txt); fi
# Termux profile first: [all] pulls desktop extras that cannot build on Android.
if ! run_pip install -e ".[termux]" "${OVERRIDE_ARGS[@]}"; then
    echo "Termux extras failed - trying base install..."
    run_pip install -e "." "${OVERRIDE_ARGS[@]}" || { echo "Hermes Agent install failed - see the error above."; exit 1; }
fi

# hermes-cli imports ruamel.yaml at startup but the extras above do not
# always pull it in — install it explicitly so `hermes setup` works.
run_pip install "ruamel.yaml" || echo "WARNING: could not install ruamel.yaml"

# Launcher inside Ubuntu.
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/hermes" << 'LAUNCHER_END'
#!/bin/bash
cd "$HOME/hermes-agent"
source venv/bin/activate
exec hermes "$@"
LAUNCHER_END
chmod +x "$HOME/.local/bin/hermes"

# One-command daily launcher: gateway first (only if not running), then chat.
cat > "$HOME/.local/bin/hermes-start.sh" << 'START_END'
#!/bin/bash
# W8BDCR Hermes - one-command daily launcher.
# Starts the gateway first (only if it is not already running),
# then opens the chat. Exiting the chat ends the session.
set -euo pipefail

# The agent lives inside the Ubuntu container.
cd "$HOME/hermes-agent" 2>/dev/null || { echo "Hermes Agent folder not found - run the installer again."; exit 1; }
[ -d venv ] || { echo "Virtual environment not found - run the installer again."; exit 1; }
source venv/bin/activate || { echo "Could not activate the virtual environment - run the installer again."; exit 1; }

GATEWAY_PID_FILE="/tmp/hermes-gateway.pid"

# True when the gateway is already running: a live PID file wins,
# otherwise fall back to pgrep when it exists.
gateway_running() {
    if [ -f "$GATEWAY_PID_FILE" ]; then
        pid="$(cat "$GATEWAY_PID_FILE" 2>/dev/null || true)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then return 0; fi
    fi
    if command -v pgrep >/dev/null 2>&1; then
        # The [y] stops pgrep matching its own command line.
        pgrep -f "hermes gatewa[y]" >/dev/null 2>&1 && return 0
    fi
    return 1
}

if gateway_running; then
    echo "Gateway is already running."
else
    echo "Starting the gateway..."
    hermes gateway run > /tmp/gateway.log 2>&1 &
    echo $! > "$GATEWAY_PID_FILE"
    # Give the gateway a few seconds to come up.
    sleep 5
fi

# Chat in the foreground - exiting ends the session.
exec hermes
START_END
chmod +x "$HOME/.local/bin/hermes-start.sh"

# Resume/repair: fix a stuck setup, then re-open setup.
cat > "$HOME/.local/bin/hermes-fix.sh" << 'FIX_END'
#!/bin/bash
# W8BDCR Hermes - resume/repair command.
# Fixes a stuck setup without wiping your config, then re-opens
# setup so you can continue from where it stopped.
# Your config in /root/.hermes is never touched.
set -uo pipefail

cd "$HOME/hermes-agent" 2>/dev/null || { echo "Hermes Agent folder not found - run the installer again."; exit 1; }
[ -d venv ] || { echo "Virtual environment not found - run the installer again."; exit 1; }
source venv/bin/activate || { echo "Could not activate the virtual environment - run the installer again."; exit 1; }

echo "Repairing your Hermes setup..."

# pip helper: uv pip when uv is present, plain pip otherwise.
run_pip() {
    if command -v uv >/dev/null 2>&1; then
        uv pip "$@"
    else
        venv/bin/python -m pip --break-system-packages "$@" \
            || venv/bin/python -m pip "$@"
    fi
}

# uv is needed for the Pillow override below - install it if missing.
if ! command -v uv >/dev/null 2>&1; then
    echo "Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1 || true
    export PATH="$HOME/.local/bin:$PATH"
    command -v uv >/dev/null 2>&1 || python3 -m pip install uv >/dev/null 2>&1 || true
fi

# 1) Known setup-breakers: install them explicitly.
echo "Reinstalling ruamel.yaml and python-dotenv..."
run_pip install "ruamel.yaml" "python-dotenv" || echo "WARNING: could not reinstall ruamel.yaml / python-dotenv"

# 2) Re-apply the Pillow 13 override (upstream pins clash: Pillow 13 vs 12).
echo "Re-applying the Pillow 13 override..."
printf 'pillow==13.0.0\n' > overrides.txt
if command -v uv >/dev/null 2>&1; then
    run_pip install --override overrides.txt "pillow==13.0.0" || echo "WARNING: Pillow override did not apply"
else
    run_pip install "pillow==13.0.0" || echo "WARNING: Pillow install did not apply"
fi

# 3) Reinstall the agent package ONLY if it is missing or broken.
# Your config in /root/.hermes is kept - this only fixes the package.
if ! hermes --version >/dev/null 2>&1; then
    echo "Hermes package looks broken - reinstalling it (config is kept)..."
    if command -v uv >/dev/null 2>&1; then
        run_pip install -e ".[termux]" --override overrides.txt \
            || run_pip install -e "." --override overrides.txt \
            || echo "WARNING: reinstall failed"
    else
        run_pip install -e ".[termux]" \
            || run_pip install -e "." \
            || echo "WARNING: reinstall failed"
    fi
fi

# 4) Verify.
echo "Verifying..."
if hermes --version; then
    echo "Hermes is working again."
else
    echo "WARNING: hermes --version is still failing - setup will show the error."
fi
hermes doctor </dev/null || true

echo "Opening setup so you can continue from where it stopped."
exec hermes setup
FIX_END
chmod +x "$HOME/.local/bin/hermes-fix.sh"
if ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
fi
export PATH="$HOME/.local/bin:$PATH"

echo ""
echo "Hermes Agent is installed inside Ubuntu."
INNER_END

warn "Step 4 - Installing Hermes Agent inside $DISTRO (5-15 minutes)..."
proot-distro login "$DISTRO" -- bash "$INNER" || { echo -e "${RED}Install inside Ubuntu failed.${RESET}"; exit 1; }

# --- Termux-level wrapper, using the container we actually used ---
cat > "$PREFIX/bin/hermes" << WRAPPER_END
#!/data/data/com.termux/files/usr/bin/bash
# W8BDCR Hermes - Termux wrapper
exec proot-distro login "$DISTRO" -- bash -lc 'source ~/hermes-agent/venv/bin/activate && exec hermes "\$@"' hermes "\$@"
WRAPPER_END
chmod +x "$PREFIX/bin/hermes" 2>/dev/null || true

cat > "$PREFIX/bin/hermes-start" << WRAPPER_END
#!/data/data/com.termux/files/usr/bin/bash
# W8BDCR Hermes - one-command daily launcher (Termux wrapper)
exec proot-distro login "$DISTRO" -- bash -lc 'exec bash "\$HOME/.local/bin/hermes-start.sh"' hermes-start
WRAPPER_END
chmod +x "$PREFIX/bin/hermes-start" 2>/dev/null || true

cat > "$PREFIX/bin/hermes-fix" << WRAPPER_END
#!/data/data/com.termux/files/usr/bin/bash
# W8BDCR Hermes - resume/repair command (Termux wrapper)
exec proot-distro login "$DISTRO" -- bash -lc 'exec bash "\$HOME/.local/bin/hermes-fix.sh"' hermes-fix
WRAPPER_END
chmod +x "$PREFIX/bin/hermes-fix" 2>/dev/null || true

echo ""
say "=============================================="
say "  W8BDCR Hermes installed successfully!"
say "=============================================="
echo ""
echo "Quick start (in Termux, just type):"
echo "  hermes setup    # first-time setup (once)"
echo "  hermes-start    # daily run - gateway + chat in one command"
echo "  hermes-fix      # setup stuck? repairs it and re-opens setup"
echo ""
echo "Already installed? Re-run this installer once - it updates"
echo "in place and adds hermes-start and hermes-fix."
echo ""
echo "Manual path (if the wrapper is missing):"
echo "  proot-distro login $DISTRO"
echo "  cd hermes-agent && source venv/bin/activate"
echo "  hermes"
echo ""
