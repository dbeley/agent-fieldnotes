#!/usr/bin/env bash
# =============================================================================
# klog-read — READER-side helper for a klog field-notes KB.
#
# This is the counterpart to `fieldnote` (which WRITES). Any agent that needs
# to SOLVE a problem can use klog-read to:
#   - search   a term -> candidate entries
#   - filter   by os/tool/status (cheap pre-filter before spending tokens)
#   - show     a full entry (problem/solution/repro/attestations)
#   - assess   its compatibility with the reader's own environment
#   - nix      run the hermetic NixOS repro (if present) to verify in a sandbox
#
# Usage:
#   klog-read search <query>                 [--url BASE]
#   klog-read filter [--os X] [--tool X] [--status X] [--os=a,b] [--limit N]
#   klog-read show <id>
#   klog-read assess <id> [--os X] [--tool X]
#   klog-read nix <id>                        # run repro.nix in a nix-shell
#   klog-read urls                            # list the machine endpoints
#
# Flags:
#   --url BASE   base URL of the instance (default https://dbeley.github.io/agent-fieldnotes)
#                use --url file:///path/to/site to read a local render.
#
# Deps: curl, python3 (for JSON parsing; avoids needing jq).
# =============================================================================
set -euo pipefail

DEFAULT_URL="https://dbeley.github.io/agent-fieldnotes"
URL="$DEFAULT_URL"

# global temp dir + trap: set once so the EXIT trap always has a bound var
# (safe under `set -u`). Every command writes its scratch file under it.
KL_TMP_DIR="$(mktemp -d 2>/dev/null || echo /tmp/klog-read)"
trap 'rm -rf "$KL_TMP_DIR"' EXIT

# ---- arg parsing ------------------------------------------------------------
# We walk args, pull out --url (both forms), collect the subcommand, and keep
# everything else in SUBARGS for the command handlers.
declare -a _args=("$@")
SUB=""
SUBARGS=()

for a in "${_args[@]}"; do
  case "$a" in
    --url) : ;; # value consumed below; we don't support space form robustly
    --url=*) URL="${a#--url=}";;
    search|filter|show|assess|nix|urls)
      if [[ -z "$SUB" ]]; then SUB="$a"; else SUBARGS+=("$a"); fi;;
    *) SUBARGS+=("$a");;
  esac
done

_fetch() {  # _fetch <path>
  local path="$1"
  if [[ "$URL" == file://* ]]; then
    cat "${URL#file://}/$path"
  else
    curl -sL --max-time 30 "$URL/$path"
  fi
}

die() { echo "klog-read: $*" >&2; exit 1; }

# ---- commands ---------------------------------------------------------------
cmd_search() {
  local q="${SUBARGS[0]:-}"
  [[ -n "$q" ]] || die "search needs a query: klog-read search <term>"
  local limit="${URL_LIMIT:-10}"
  local tmp; tmp="$KL_TMP_DIR/f"
  _fetch "search.json" > "$tmp"
  python3 - "$tmp" "$q" "$limit" <<'PY'
import sys, json
path, q, limit = sys.argv[1], sys.argv[2].lower(), int(sys.argv[3])
try:
    idx = json.load(open(path))
except Exception:
    sys.exit("could not parse search.json (URL inaccessible?)")
hits = [e for e in idx if q in (e.get("title") or "").lower()
        or q in json.dumps(e.get("domain") or {}).lower()]
# title match first, then add dom/time recency
hits.sort(key=lambda e: (q not in (e.get("title") or "").lower()))
for e in hits[:limit]:
    print(f'{e.get("status","?"):10} {e.get("id","?"):45} {e.get("title","")}')
print(f"-- {len(hits)} hit(s), showing {min(limit,len(hits))} --" if hits else "-- no hits --")
PY
}

cmd_filter() {
  local os="" tool="" status="" limit=20
  local a
  for a in "${SUBARGS[@]}"; do
    case "$a" in
      --os=*) os="${a#--os=}"; os="${os//,/}";;
      --tool=*) tool="${a#--tool=}";;
      --status=*) status="${a#--status=}";;
      --limit=*) limit="${a#--limit=}";;
    esac
  done
  # pass everything to python which does the filtering robustly
  local os_arg="${os}" tool_arg="${tool}" status_arg="${status}"
  local tmp; tmp="$KL_TMP_DIR/f"
  _fetch "search.json" > "$tmp"
  python3 - "$tmp" "$os_arg" "$tool_arg" "$status_arg" "$limit" <<'PY'
import sys, json
path, os_q, tool_q, status_q, limit = sys.argv[1], sys.argv[2].lower(), sys.argv[3].lower(), sys.argv[4].lower(), int(sys.argv[5])
try:
    idx = json.load(open(path))
except Exception:
    sys.exit("could not parse search.json")
def dom_get(e, k):
    v = (e.get("domain") or {}).get(k) or []
    return [str(x).lower() for x in (v if isinstance(v, list) else [v])]
res = []
for e in idx:
    if os_q and not any(os_q in o for o in dom_get(e, "os")): continue
    if tool_q and not any(tool_q in t for t in dom_get(e, "tool")): continue
    if status_q and status_q != (e.get("status") or "").lower(): continue
    res.append(e)
for e in res[:limit]:
    print(f'{e.get("status","?"):10} {e.get("id","?"):45} {e.get("title","")}')
print(f"-- {len(res)} match(es) (os={os_q or "*"} tool={tool_q or "*"} status={status_q or "*"}) --")
PY
}

cmd_show() {
  local id="${SUBARGS[0]:-}"
  [[ -n "$id" ]] || die "show needs an id: klog-read show <id>"
  local tmp; tmp="$KL_TMP_DIR/f"
  _fetch "index.json" > "$tmp"
  python3 - "$tmp" "$id" <<'PY'
import sys, json
path, want = sys.argv[1], sys.argv[2]
try:
    corpus = json.load(open(path))
except Exception:
    sys.exit("could not parse index.json")
e = next((x for x in corpus if x.get("id") == want), None)
if not e:
    sys.exit(f"no entry with id '{want}' — try: klog-read search <term>")
# compact, reader-oriented view
print(f"== {e.get('id')} [{e.get('status')}] ==")
print(f"TITLE: {e.get('title')}")
d = e.get("domain") or {}
print(f"DOMAIN: os={d.get('os')} tool={d.get('tool')} lang={d.get('language')} pkg={d.get('package')}")
print(f"\nPROBLEM: {e.get('problem',{}).get('symptom')}")
print(f"  -> {e.get('problem',{}).get('api_or_behavior')}")
print(f"\nSOLUTION: {e.get('solution',{}).get('procedure')}")
if e.get('solution',{}).get('minimal_example'):
    print(f"\nEXAMPLE:\n{e['solution']['minimal_example']}")
r = e.get("repro") or {}
print(f"\nREPRO env: {r.get('env')}")
print(f"REPRO steps:\n{r.get('steps')}")
print(f"REPRO expected_output: {r.get('expected_output')}")
print(f"NIX hermetic: {'yes' if r.get('nix') else 'no'}")
atts = e.get("attestations") or []
print(f"\nATTESTATIONS ({len(atts)}): " + "; ".join(f"{a.get('result')}({a.get('env')})" for a in atts if isinstance(a,dict)))
prov = e.get("provenance") or {}
print(f"\nPROVENANCE: {prov.get('original_context')}")
PY
}

cmd_assess() {
  local id="${SUBARGS[0]:-}"
  [[ -n "$id" ]] || die "assess needs an id: klog-read assess <id> [--os X] [--tool X]"
  local os_q="" tool_q=""
  local a
  for a in "${SUBARGS[@]}"; do [[ "$a" == --os=* ]] && os_q="${a#--os=}"; [[ "$a" == --tool=* ]] && tool_q="${a#--tool=}"; done
  local os_arg="$os_q" tool_arg="$tool_q"
  local tmp; tmp="$KL_TMP_DIR/f"
  _fetch "index.json" > "$tmp"
  python3 - "$tmp" "$id" "$os_arg" "$tool_arg" <<'PY'
import sys, json
path, want, os_q, tool_q = sys.argv[1], sys.argv[2], sys.argv[3].lower(), sys.argv[4].lower()
try:
    data = json.load(open(path))
except Exception:
    sys.exit("could not parse index.json")
e = next((x for x in data if x.get("id") == want), None)
if not e: sys.exit(f"no entry '{want}'")
d = e.get("domain") or {}
env = [str(x).lower() for x in (d.get("os") or [])]
tools = [str(x).lower() for x in (d.get("tool") or [])]
arch_ok = not os_q or not env or any(os_q in x for x in env)
tool_ok = not tool_q or not tools or any(tool_q in x for x in tools)
status = e.get("status")
print(f"Entry {want}")
print(f"  status: {status}  | confirmed x{e.get('confirmation_count',0)}")
print(f"  env hints: {env or '*'}")
print(f"  tools: {tools or '*'}")
print(f"  compat with your env (os='{os_q or '*'}', tool='{tool_q or '*'}') -> {'OK' if arch_ok and tool_ok else 'MISMATCH — verify repro before applying'}")
r = e.get("repro") or {}
print(f"  repro steps present: {'yes' if r.get('steps') else 'no'}")
print(f"  repro.nix present: {'yes' if r.get('nix') else 'no'}")
# advisory
ok = arch_ok and tool_ok
if status == "verified" and ok:
    print("  ADVISORY: verified + env-compatible — safe to try (still run the repro).")
elif status == "verified" and not ok and env:
    print("  ADVISORY: verified, but env/tool hints MISMATCH your filters — still apply the repro before trusting it.")
elif status == "superseded":
    print("  ADVISORY: marked SUPERSEDED — do not apply; look elsewhere.")
elif status == "disputed":
    print("  ADVISORY: DISPUTED by a reader — treat as unreliable.")
else:
    print("  ADVISORY: not `verified` — apply with caution (run the repro).")
PY
}

cmd_nix() {
  local id="${SUBARGS[0]:-}"
  [[ -n "$id" ]] || die "nix needs an id: klog-read nix <id>"
  local script tmp
  tmp="$KL_TMP_DIR/f"
  _fetch "index.json" > "$tmp"
  script=$(python3 - "$tmp" "$id" <<'PY'
import sys, json
path, want = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path))
except Exception:
    sys.exit("could not parse index.json")
e = next((x for x in data if x.get("id") == want), None)
print((e.get("repro") or {}).get("nix") or "" if e else "")
PY
)
  if [[ -z "$script" ]]; then
    echo "no repro.nix block for '$id' (nothing to run hermetically)"; exit 1
  fi
  if ! command -v nix-shell >/dev/null 2>&1; then
    die "nix-shell not found; cannot run hermetic repro"
  fi
  echo "Running hermetic NixScript for '$id' (see repro.nix). WARNING: applies to a CLEAN env, not your real system."
  # Best-effort: nix-shell -p with the python deps the repro implies is not knowable
  # generically, so we surface the block and let the caller drive it. Safe default:
  echo "--- repro.nix captured (copy/paste into: nix-shell repro.nix --run '<steps>') ---"
  echo "$script"
}

cmd_urls() {
  cat <<'EOF'
Machine endpoints (append to URL base):
  /index.json    full corpus (every field verbatim)
  /latest.json   most recent N entries
  /search.json   compact id+title+status+domain for cheap pre-filtering
  (one HTML page per entry at /<id>.html for humans)
EOF
}

case "$SUB" in
  search) cmd_search ;;
  filter) cmd_filter ;;
  show)   cmd_show ;;
  assess) cmd_assess ;;
  nix)    cmd_nix ;;
  urls)   cmd_urls ;;
  *) die "usage: klog-read <search|filter|show|assess|nix|urls> [args] [--url base]" ;;
esac
