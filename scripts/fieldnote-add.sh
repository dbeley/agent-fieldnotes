#!/usr/bin/env bash
# =============================================================================
# fieldnote-add — create a new klog draft entry for the agent-fieldnotes KB.
#
# Any agent (opencode, hermes, codex, claude, ...) on any machine can use this
# to contribute a finding. It:
#   1. pulls the latest repo state (rebasing over remote work, no clobber)
#   2. copies templates/_template.yaml to entries/<id>.yaml  (draft)
#   3. seeds id + title from the argument
#   4. validates every entry (schema + trust gate) locally
#   5. prints the exact next commands (fill it in, then commit + push)
#
# Usage:
#   fieldnote-add "One line title of the finding"
#   FIELDNOTES_REPO=/path/to/repo fieldnote-add "title"    # custom repo path
#
# Exit codes: 0 = entry created ok; 1 = title missing; 2 = repo not found;
#             3 = validation failed (schema error left for you to fix).
# =============================================================================
set -euo pipefail

REPO="${FIELDNOTES_REPO:-$HOME/workspace/projects/agent-fieldnotes}"
TITLE="${1:-}"

_next_commands() {
  local _id="$1"
  echo "  \$EDITOR entries/$_id.yaml"
  echo "  git add entries/$_id.yaml"
  echo "  git commit -m 'fieldnote: $_id'"
  echo "  git push origin main"
}

if [[ -z "$TITLE" ]]; then
  echo "usage: fieldnote-add \"<one-line title>\"" >&2
  exit 1
fi
if [[ ! -d "$REPO/.git" ]]; then
  echo "fieldnotes repo not found at $REPO (set FIELDNOTES_REPO or clone it)" >&2
  exit 2
fi
if [[ ! -f "$REPO/templates/_template.yaml" ]]; then
  echo "missing templates/_template.yaml in $REPO — repo out of date? run: git pull" >&2
  exit 2
fi

ID="$(printf '%s' "$TITLE" | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-60)"
if [[ -z "$ID" ]]; then
  ID="untitled-$(date +%s)"
fi

cd "$REPO"
# fast-forward over remote discoveries; abort silently if any conflict
git pull --rebase --autostash origin main >/dev/null 2>&1 || \
  echo "note: could not auto-pull; continuing with local state" >&2

if [[ -e "entries/$ID.yaml" ]]; then
  echo "entry already exists: entries/$ID.yaml" >&2
  exit 1
fi

cp templates/_template.yaml "entries/$ID.yaml"
# seed id + title (id must equal filename); keep template's placeholder dates
sed -i "s/^id:.*/id: $ID/" "entries/$ID.yaml"
sed -i "s|^title:.*|title: \"$TITLE\"|" "entries/$ID.yaml"

# validate all entries (schema conformance + trust gate). Need PyYAML.
if command -v nix-shell >/dev/null 2>&1; then
  nix_shell_cmd="nix-shell -p python3Packages.pyyaml --run"
elif command -v uv >/dev/null 2>&1; then
  nix_shell_cmd="uv run --with pyyaml"
else
  echo "WARNING: neither nix-shell nor uv found; skipping local validation (CI will check)" >&2
  echo "created entries/$ID.yaml (status: draft)"
  _next_commands "$ID"
  exit 0
fi

if $nix_shell_cmd "python3 scripts/validate_klog.py entries/*.yaml"; then
  echo
  echo "✔ created draft entry: entries/$ID.yaml"
  echo "──────────────────────────────────────────────"
  echo "Next (fill in problem/solution/repro first, then):"
  _next_commands "$ID"
  exit 0
else
  echo "✖ validation failed — fix entries/$ID.yaml, then re-run:" >&2
  _next_commands "$ID" >&2
  exit 3
fi
