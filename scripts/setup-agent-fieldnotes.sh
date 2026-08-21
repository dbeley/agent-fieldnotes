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

# --- 2. install the `fieldnote` command -------------------------------------
mkdir -p "$BIN_DIR"
FIELDNOTE_BIN="$BIN_DIR/fieldnote"
cat > "$FIELDNOTE_BIN" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
REPO="${XDG_DATA_HOME:-$HOME/.local/share}/agent-fieldnotes"
if [[ ! -d "$REPO/.git" ]]; then
  mkdir -p "$(dirname "$REPO")"
  echo "cloning agent-fieldnotes KB -> $REPO" >&2
  git clone --depth 1 https://github.com/dbeley/agent-fieldnotes.git "$REPO"
fi
export FIELDNOTES_REPO="$REPO"
exec "$REPO/scripts/fieldnote-add.sh" "$@"
SCRIPT
chmod +x "$FIELDNOTE_BIN"
echo "    installed command: $FIELDNOTE_BIN"

# --- 3. report wiring points -------------------------------------------------
echo
echo "==> done."
echo "    'fieldnote' is now available at: $FIELDNOTE_BIN"
echo "    KB clone: $REPO_DIR"
echo
echo "    If $BIN_DIR is not on your PATH, add it, then run:  fieldnote"
echo "    To wire the capture protocol into opencode, append the block below to"
echo "    ~/.config/opencode/AGENTS.md (or use the agent-fieldnotes Hermes skill):"
echo
echo '    ------- begin capture protocol -------'
echo '    ## Field notes (klog) — capture while you work'
echo '    If you discover something undocumented + reusable, publish it:'
echo '      1. fieldnote "one line title"        # clones KB, makes a draft'
echo '      2. edit entries/<id>.yaml, then:'
echo '         git -C ~/.local/share/agent-fieldnotes add entries/<id>.yaml'
echo '         git -C ~/.local/share/agent-fieldnotes commit && git -C ~/.local/share/agent-fieldnotes push'
echo '    Do NOT publish trivial/obvious/secrets. Mark drafts; CI requires proof to verify.'
echo '    ------- end capture protocol -------'
