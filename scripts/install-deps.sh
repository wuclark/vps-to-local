#!/usr/bin/env bash
# install-deps.sh — Install local prerequisites for vps-to-local scripts
#
# Installs wireguard-tools on the local machine so that scripts/gen-keys.sh
# and other commands that call 'wg' work out of the box.
#
# VPS-side prerequisites are handled separately by vps/setup.sh — run that
# over SSH on the VPS itself, not here.
#
# Usage:
#   bash scripts/install-deps.sh        # Linux (prompts for sudo as needed)
#   bash scripts/install-deps.sh        # macOS (installs Homebrew if absent)
#
# Supported:
#   Ubuntu / Debian / Raspberry Pi OS   apt
#   Fedora / RHEL / CentOS / Rocky      dnf
#   Arch / Manjaro                      pacman
#   macOS                               Homebrew

set -euo pipefail

# ── Already satisfied? ─────────────────────────────────────────────────────────
if command -v wg &>/dev/null; then
    echo "wireguard-tools is already installed."
    wg --version 2>/dev/null || true
    echo "Nothing to do — run: bash scripts/gen-keys.sh"
    exit 0
fi

# ── Detect OS and install ──────────────────────────────────────────────────────
OS="$(uname -s)"

install_apt() {
    echo "==> Installing wireguard-tools via apt..."
    if [[ "$EUID" -eq 0 ]]; then
        apt-get update -qq
        apt-get install -y wireguard-tools
    else
        sudo apt-get update -qq
        sudo apt-get install -y wireguard-tools
    fi
}

install_dnf() {
    echo "==> Installing wireguard-tools via dnf..."
    sudo dnf install -y wireguard-tools
}

install_pacman() {
    echo "==> Installing wireguard-tools via pacman..."
    sudo pacman -Sy --noconfirm wireguard-tools
}

install_brew() {
    if ! command -v brew &>/dev/null; then
        echo "==> Homebrew not found — installing..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    echo "==> Installing wireguard-tools via Homebrew..."
    brew install wireguard-tools
}

case "$OS" in
    Linux)
        if [[ ! -f /etc/os-release ]]; then
            echo "ERROR: Cannot detect Linux distro (/etc/os-release missing)." >&2
            echo "  Install wireguard-tools manually: https://www.wireguard.com/install/" >&2
            exit 1
        fi
        # shellcheck source=/dev/null
        . /etc/os-release
        case "${ID:-}" in
            ubuntu|debian|raspbian|linuxmint|pop)
                install_apt ;;
            fedora|rhel|centos|rocky|almalinux)
                install_dnf ;;
            arch|manjaro|endeavouros|garuda)
                install_pacman ;;
            *)
                # Last-ditch: check if apt or dnf is available
                if command -v apt-get &>/dev/null; then
                    install_apt
                elif command -v dnf &>/dev/null; then
                    install_dnf
                elif command -v pacman &>/dev/null; then
                    install_pacman
                else
                    echo "ERROR: Unsupported distro '${ID:-unknown}'." >&2
                    echo "  Install wireguard-tools manually:" >&2
                    echo "    https://www.wireguard.com/install/" >&2
                    exit 1
                fi
                ;;
        esac
        ;;

    Darwin)
        install_brew
        ;;

    *)
        echo "ERROR: Unsupported OS '$OS'." >&2
        echo "  Install wireguard-tools manually: https://www.wireguard.com/install/" >&2
        exit 1
        ;;
esac

# ── Verify ─────────────────────────────────────────────────────────────────────
echo ""
if command -v wg &>/dev/null; then
    echo "Done. wireguard-tools installed."
    echo ""
    echo "Next: bash scripts/gen-keys.sh"
else
    echo "ERROR: Installation finished but 'wg' command still not found." >&2
    echo "  Try opening a new shell, or install manually:" >&2
    echo "    https://www.wireguard.com/install/" >&2
    exit 1
fi
