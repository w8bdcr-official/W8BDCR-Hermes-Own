# W8BDCR Hermes — Termux

Own W8BDCR installer for the Hermes AI agent on Android (Termux).

## How it works

Same working process, written by W8BDCR:

1. Update Termux packages
2. Prepare / reuse an Ubuntu container with proot-distro
3. Inside Ubuntu: install Python, git and build tools, pick a Hermes-compatible
   Python (3.14+, via uv when the system Python is older — upstream deps
   require 3.14)
4. Download Hermes Agent, create a virtual environment, install it
5. Add a Termux-level `hermes` command, so you do not need to log into
   the container by hand

## Install

In Termux:

```bash
curl -fsSL https://raw.githubusercontent.com/w8bdcr-official/W8BDCR-Hermes-Own/main/install.sh | bash
```

## Quick start

```bash
hermes setup    # first-time setup
hermes          # start chatting
hermes gateway  # run the gateway
```

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/w8bdcr-official/W8BDCR-Hermes-Own/main/uninstall.sh | bash
```

## Note

This installer is W8BDCR's own code. The agent itself is the upstream
open-source Hermes Agent project, downloaded fresh at install time.
