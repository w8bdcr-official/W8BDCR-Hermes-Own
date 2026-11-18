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

# Shared helper: make sure the gateway is running (only if it is not).
# Every hermes command uses this - the server starts itself when needed.
# Assumes the venv is already activated by the caller (hermes is on PATH).
# Safe to run as a child script: it only prints short lines, exits 0.
cat > "$HOME/.local/bin/hermes-ensure-gateway.sh" << 'ENSURE_END'
#!/bin/bash
# W8BDCR Hermes - shared gateway check.
# Starts the gateway first (only if it is not already running) and WAITS
# until it actually answers. A fixed sleep is not enough on a phone: the
# gateway can take 30-90s to come up, and the chat fails if it connects
# too early ("Gateway connection failed; no local fallback").
# Used by `hermes` (any command) and by `hermes-start`.
#
# READINESS = a well-formed `identify` answer with state "ready" on the
# gateway's control socket. That is upstream's own definition of liveness
# ("A connectable socket with a well-formed `identify` answer IS liveness",
# gateway/control_socket.py). A bare socket connect() is NOT proof: it
# succeeds as soon as the socket listens, even while the gateway is still
# "starting" and serves nothing (the listen backlog answers the connect).
#
# HISTORY (why this version exists): v11 verified readiness with a bare
# connect plus `pgrep -f "hermes gatewa[y]"`. That pgrep pattern NEVER
# matches the daemon's real command line
# (`python -m hermes_cli.main --profile default gateway run --quiet`),
# and `gateway ensure` writes no PID file of its own, so after a
# successful `gateway ensure` the script wrongly concluded the gateway was
# missing and started a SECOND gateway while the first was alive and
# ready. The second boot raced the first for the lock and loaded the
# phone's weak CPU while the chat tried to attach, and the attach then
# failed ("Gateway connection failed; no local fallback") 8 times in a row
# (2026-11-17/18, reproduced byte-for-byte on this VM). The one run that
# ever worked (2026-11-17 18:03) had no second gateway. This version
# NEVER starts a second gateway while one is starting or ready: it only
# spawns when `identify` proves nothing is there.
GATEWAY_WAIT_SECONDS=90

# Print one word: the gateway's live state as its control socket reports
# it ("ready", "starting", "draining", "conflict", "absent",
# "inaccessible"). A socket that exists but does not serve identify yet
# means "starting" while its owner is alive, "absent" once the owner is
# gone - never a second gateway while one is starting.
gateway_state() {
    python3 - "$HOME" << 'PYEOF'
import json
import os
import socket
import sys

home = sys.argv[1]
hermes_home = os.path.join(home, ".hermes")

def live_owner_pid():
    """PID from the gateway's own pid record, if that process is provably the gateway.

    The record carries the raw starttime ticks from /proc/<pid>/stat, so a
    recycled PID is rejected when its start ticks differ (same guard as
    upstream's gateway.status._live_pid_from_record)."""
    try:
        with open(os.path.join(hermes_home, "gateway.pid"), "r", encoding="utf-8") as f:
            record = json.load(f)
    except (OSError, ValueError):
        return None
    pid = record.get("pid")
    if not isinstance(pid, int) or pid <= 0:
        return None
    try:
        os.kill(pid, 0)
    except OSError:
        return None
    try:
        start_ticks = int(open(f"/proc/{pid}/stat", "r", encoding="utf-8").read().rsplit(")", 1)[1].split()[19])
        if abs(float(record.get("start_time") or 0) - start_ticks) > 200:
            return None
    except (OSError, ValueError, IndexError):
        pass
    return pid

def resolve_socket():
    direct = os.path.join(hermes_home, "gateway.sock")
    if os.path.lexists(direct):
        return direct
    pointer = os.path.join(hermes_home, "gateway.sock.path")
    try:
        with open(pointer, "r", encoding="utf-8") as f:
            target = f.read().strip()
        if target.startswith("/"):
            return target
    except OSError:
        return None
    return None

path = resolve_socket()
if not path:
    print("starting" if live_owner_pid() else "absent")
    sys.exit(0)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(2)
try:
    s.connect(path)
except OSError:
    print("starting" if live_owner_pid() else "absent")
    sys.exit(0)
s.settimeout(5)
try:
    s.sendall(b'{"protocol":1,"verb":"identify","id":1}\n')
    data = b""
    while b"\n" not in data:
        chunk = s.recv(65536)
        if not chunk:
            raise OSError("socket closed without an identify answer")
        data += chunk
        if len(data) > 524288:
            raise ValueError("identify answer too large")
    resp = json.loads(data.split(b"\n", 1)[0])
    if resp.get("ok") is not True or resp.get("protocol") != 1 or resp.get("id") != 1:
        raise ValueError("malformed identify answer")
    state = resp["result"].get("state")
    if not isinstance(state, str) or not state:
        raise ValueError("identify answer has no state")
    print(state)
except (OSError, ValueError, KeyError, TypeError):
    # The socket exists but identify is not served yet: the gateway is
    # still starting (or wedged mid-start). Only a dead owner means it
    # will never answer, so only then call it absent.
    print("starting" if live_owner_pid() else "absent")
finally:
    s.close()
PYEOF
}

# Wait until `identify` reports "ready" (up to $GATEWAY_WAIT_SECONDS).
# $1 = PID to watch (may be empty: then only the socket state is watched).
# Prints "Gateway is ready." exactly once on success; on failure prints
# the real cause from the gateway logs (the daemon's own stdio log first -
# that is where its startup output actually goes - then our fallback log).
wait_for_ready() {
    local waited=0 watch_pid="$1" state="" seen_live=0
    while [ "$waited" -lt "$GATEWAY_WAIT_SECONDS" ]; do
        if [ -n "$watch_pid" ] && ! kill -0 "$watch_pid" 2>/dev/null; then
            echo "Gateway stopped while starting. Last lines of the gateway logs:"
            tail -20 "$HOME/.hermes/logs/gateway-stdio.log" 2>/dev/null || true
            tail -20 /tmp/gateway.log 2>/dev/null || true
            return 1
        fi
        state="$(gateway_state)"
        case "$state" in
            ready)
                echo "Gateway is ready."
                return 0
                ;;
            starting|draining|conflict)
                seen_live=1
                ;;
            absent)
                if [ "$seen_live" = 1 ]; then
                    # The gateway we were waiting for went away: waiting
                    # longer cannot bring it back; let the caller retry.
                    echo "Gateway went away while starting (state: absent). Last lines of the gateway logs:"
                    tail -20 "$HOME/.hermes/logs/gateway-stdio.log" 2>/dev/null || true
                    tail -20 /tmp/gateway.log 2>/dev/null || true
                    return 1
                fi
                ;;
        esac
        sleep 2
        waited=$((waited + 2))
    done
    echo "Gateway did not become ready within ${GATEWAY_WAIT_SECONDS}s (last state: $state). Last lines of the gateway logs:"
    tail -20 "$HOME/.hermes/logs/gateway-stdio.log" 2>/dev/null || true
    tail -20 /tmp/gateway.log 2>/dev/null || true
    return 1
}

cd "$HOME/hermes-agent" 2>/dev/null || true
# Verified gateway start (v12): "ready" is only claimed after a REAL
# `identify` answer proves the gateway serves, AND a live gateway process
# exists. `hermes gateway ensure` alone is NOT proof - it has returned
# success while no gateway stayed alive, and the chat then failed with
# "Gateway connection failed; no local fallback" (seen 8 times,
# 2026-11-17/18). Up to 3 attempts; on total failure the real log tails
# are printed and this script exits non-zero, so the wrapper never opens
# a chat that is guaranteed to fail.
# The one rule that matters: NEVER start a second gateway while one is
# starting or ready. A second boot races the first for the lock and loads
# the phone while the chat attaches - that was the 8 failures.
attempt=1
while [ "$attempt" -le 3 ]; do
    state="$(gateway_state)"
    case "$state" in
        ready)
            echo "Gateway is already running."
            exit 0
            ;;
        inaccessible)
            echo "Gateway control socket is not usable by this user (state: inaccessible)."
            echo "Check with: hermes gateway status"
            exit 1
            ;;
        starting|draining|conflict)
            # A gateway is alive and working through startup (or draining
            # after an idle exit): wait for it, do not start another one.
            echo "Gateway is starting... (attempt $attempt/3)"
            if wait_for_ready; then
                exit 0
            fi
            ;;
        *)
            # absent (or an unusable reply): nothing usable is running.
            echo "Starting the gateway... (attempt $attempt/3)"
            # 1) Upstream's own readiness wait: starts the gateway if needed
            #    and waits until it answers. Older Hermes versions have no
            #    `gateway ensure` - then this fails fast and the fallback
            #    takes over.
            if hermes gateway ensure --timeout "$GATEWAY_WAIT_SECONDS" >/dev/null 2>&1; then
                # ensure claimed success - VERIFY with identify before believing it.
                if [ "$(gateway_state)" = "ready" ]; then
                    echo "Gateway is ready."
                    exit 0
                fi
                echo "Gateway said ready but is not answering identify - retrying..."
            fi
            # 2) Only spawn our own gateway when identify proves nothing
            #    is there at all. If one is starting, wait for it instead.
            state="$(gateway_state)"
            if [ "$state" = "starting" ] || [ "$state" = "draining" ] || [ "$state" = "conflict" ]; then
                if wait_for_ready; then
                    exit 0
                fi
            elif [ "$state" != "ready" ]; then
                # Detached like upstream's own spawn (start_new_session):
                # it must outlive this script, whatever runs it.
                setsid hermes gateway run > /tmp/gateway.log 2>&1 < /dev/null &
                gw_pid=$!
                if wait_for_ready "$gw_pid"; then
                    exit 0
                fi
            fi
            ;;
    esac
    attempt=$((attempt + 1))
    sleep 2
done
echo "Gateway could not be started after 3 attempts. Last lines of the gateway logs:"
tail -25 "$HOME/.hermes/logs/gateway-stdio.log" 2>/dev/null || true
tail -25 /tmp/gateway.log 2>/dev/null || true
exit 1
ENSURE_END
chmod +x "$HOME/.local/bin/hermes-ensure-gateway.sh"

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

# Shared gateway check - starts the gateway only if it is not running.
# If it cannot start, stop here with the real log instead of opening
# a chat that is guaranteed to fail with "Gateway connection failed".
bash "$HOME/.local/bin/hermes-ensure-gateway.sh" || { echo "Hermes gateway could not start - the log above shows why."; exit 1; }

# Work where the user typed the command: if the wrapper passed the
# folder they were standing in (HERMES_START_DIR) and it exists inside
# this container (e.g. /sdcard/... is shared), open the chat there so
# the agent sees their project files. Otherwise stay here.
cd "${HERMES_START_DIR:-}" 2>/dev/null || true

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
# Any hermes command just works: the gateway starts itself when needed.
# Only "hermes gateway ..." runs as-is (no auto-start inside a gateway
# command - it IS the gateway).
# Starts in the folder you typed the command in, when that folder is
# visible inside Ubuntu (e.g. /sdcard/...). Otherwise starts at home.
HERMES_START_DIR="\$PWD" exec proot-distro login "$DISTRO" -- bash -lc 'source ~/hermes-agent/venv/bin/activate; if [ "\${1:-}" != "gateway" ] && [ -f "\$HOME/.local/bin/hermes-ensure-gateway.sh" ]; then if ! bash "\$HOME/.local/bin/hermes-ensure-gateway.sh"; then if [ \$# -eq 0 ]; then echo "Hermes gateway could not start - the log above shows why."; exit 1; fi; fi; fi; cd "\${HERMES_START_DIR:-}" 2>/dev/null || true; exec hermes "\$@"' hermes "\$@"
WRAPPER_END
chmod +x "$PREFIX/bin/hermes" 2>/dev/null || true

cat > "$PREFIX/bin/hermes-start" << WRAPPER_END
#!/data/data/com.termux/files/usr/bin/bash
# W8BDCR Hermes - one-command daily launcher (Termux wrapper)
HERMES_START_DIR="\$PWD" exec proot-distro login "$DISTRO" -- bash -lc 'exec bash "\$HOME/.local/bin/hermes-start.sh"' hermes-start
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
echo "  hermes          # just use it - the server starts itself when needed"
echo "  hermes-start    # explicit full run - gateway + chat in one command"
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
