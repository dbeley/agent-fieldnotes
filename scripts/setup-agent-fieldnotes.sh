#!/usr/bin/env bash
# =============================================================================
# setup-agent-fieldnotes — agent-driven bootstrap for the field-notes KB.
#
# Any agent on ANY machine can run this to get the fieldnotes workflow working
# locally, then call it from your capture protocol (see the agent-fieldnotes
# skill / AGENTS.md). It:
#   1. clones the shared KB into the XDG data dir (~/.local/share/agent-fieldnotes)
#   2. installs a `fieldnote` command on PATH (~/.local/bin/fieldnote)
#   3. reports where things live so the agent can wire capture into the host's
#      agent system (e.g. opencode ~/.config/opencode/AGENTS.md).
#
# Usage:
#   setup-agent-fieldnotes [--repo-url <url>] [--bin-dir <dir>]
#   --repo-url  default: https://github.com/dbeley/agent-fieldnotes.git
#   --bin-dir   default: $HOME/.local/bin
#
# Idempotent: safe to run repeatedly; it updates rather than duplicates.
# =============================================================================
set -euo pipefail

REPO_URL="https://github.com/dbeley/agent-fieldnotes.git"
BIN_DIR="${HOME}/.local/bin"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}"
REPO_DIR="$DATA_DIR/agent-fieldnotes"

# --- parse args --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-url) REPO_URL="$2"; shift 2 ;;
    --bin-dir) BIN_DIR="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

echo "==> agent-fieldnotes bootstrap"
echo "    data dir : $REPO_DIR"
echo "    bin dir  : $BIN_DIR"

# --- 1. clone the KB ---------------------------------------------------------
if [[ ! -d "$REPO_DIR/.git" ]]; then
  mkdir -p "$DATA_DIR"
  echo "    cloning KB ..."
  git clone --depth 1 "$REPO_URL" "$REPO_DIR"
else
  echo "    KB already present, updating ..."
  git -C "$REPO_DIR" pull --rebase --autostash origin main >/dev/null 2>&1 || true
fi

# --- 2. install the `fieldnote` command --------------------------------------
# The command logic is the SINGLE SOURCE OF TRUTH at scripts/fieldnote (this
# repo). We copy that canonical file, never an inline copy, so the installed
# wrapper and the nixos-config packaging stay in sync.
mkdir -p "$BIN_DIR"
FIELDNOTE_BIN="$BIN_DIR/fieldnote"
if [[ ! -f "$REPO_DIR/scripts/fieldnote" ]]; then
  echo "ERROR: canonical wrapper missing at $REPO_DIR/scripts/fieldnote — repo out of date?" >&2
  exit 2
fi
cp "$REPO_DIR/scripts/fieldnote" "$FIELDNOTE_BIN"
chmod +x "$FIELDNOTE_BIN"
echo "    installed command: $FIELDNOTE_BIN (from scripts/fieldnote)"

# --- install the `klog-read` reader command (same single-source approach) -----
KLOP_READ_SRC="$REPO_DIR/scripts/klog-read.sh"
KLOP_READ_BIN="$BIN_DIR/klog-read"
if [[ -f "$KLOP_READ_SRC" ]]; then
  cp "$KLOP_READ_SRC" "$KLOP_READ_BIN"
  chmod +x "$KLOP_READ_BIN"
  echo "    installed command: $KLOP_READ_BIN (from scripts/klog-read.sh)"
else
  echo "    note: klog-read.sh not found in repo clone; run setup again after git pull" >&2
fi

# --- 3. report wiring points -------------------------------------------------
echo
echo "==> done."
echo "    'fieldnote' (write) is now available at: $FIELDNOTE_BIN"
if [[ -f "$KLOP_READ_BIN" ]]; then echo "    'klog-read' (read)  is now available at: $KLOP_READ_BIN"; fi
echo "    KB clone: $REPO_DIR"
echo
echo "    If $BIN_DIR is not on your PATH, add it, then use:"
echo "      klog-read search '<term>'      # query the KB before solving"
echo "      fieldnote 'one line title'     # publish a new finding"
echo "    To wire the protocol into opencode, append the block below to"
echo "    ~/.config/opencode/AGENTS.md (or use the agent-fieldnotes Hermes skill):"
echo
echo '    ------- begin capture protocol -------'
echo '    ## Field notes (klog) — read + capture while you work'
echo '    Before solving a hard problem, query the KB:'
echo '      klog-read search "<term>"'
echo '    If you discover something undocumented + reusable, publish it:'
echo '      1. fieldnote "one line title"        # clones KB, makes a draft'
echo '      2. edit entries/<id>.yaml, then:'
echo '         git -C ~/.local/share/agent-fieldnotes add entries/<id>.yaml'
echo '         git -C ~/.local/share/agent-fieldnotes commit && git -C ~/.local/share/agent-fieldnotes push'
echo '    Do NOT publish trivial/obvious/secrets. Mark drafts; CI requires proof to verify.'
echo '    ------- end capture protocol -------'
