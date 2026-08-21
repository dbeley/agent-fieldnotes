#!/usr/bin/env python3
"""
klog validator — the CI trust gate.

Validates every entries/*.yaml against schema/klog.yaml rules:

  FAIL (exit 1) if:
    - a required field is missing
    - `id` does not match the filename
    - `status` is not one of the enumerated values
    - `repro` / `expected_output` are missing (verifiability bar)
    - `status: verified` but `confirmation_count < 1` and no confirm attestation
      (you cannot PROVE something you cannot demonstrate)

  WARN (never fails) if:
    - an entry claims `verified` with no `nix` repro (NixOS-reader fast path)
    - LICENSE is not CC0 (limits redistribution)

Run:  python3 validate.py            (checks schema/klog.yaml + entries/)
      python3 validate.py entries/*.yaml
Exit code 0 on all-pass, 1 if any entry is invalid.

Dependencies: PyYAML. In CI run with: uv run --with pyyaml python validate.py
"""

import os
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("PyYAML is required. Install with: uv pip install pyyaml")

ROOT = Path(__file__).resolve().parent
SCHEMA_PATH = ROOT / "schema" / "klog.yaml"
ENTRIES_DIR = ROOT / "entries"

STATUSES = {"draft", "verified", "disputed", "superseded"}
RESULTS = {"confirm", "deny", "partial"}
REQUIRED_TOP = {"id", "status", "title", "first_seen", "problem", "solution", "repro"}
REQUIRED_PROBLEM = {"symptom", "api_or_behavior"}
REQUIRED_SOLUTION = {"procedure"}
REQUIRED_REPRO = {"env", "steps", "expected_output"}

# An entry that claims to be `verified` must be demonstrable: either a confirm
# attestation exists, or confirmation_count >= 1.
VALIDATED_SELF_CONSISTENCY = True


def load_yaml(path):
    with open(path, "r", encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def check_required(mapping, keys, where):
    missing = [k for k in keys if not mapping.get(k)]
    if missing:
        return [f"{where}: missing required field(s): {', '.join(missing)}"]
    return []


def validate_entry(path):
    errors, warnings = [], []
    try:
        entry = load_yaml(path)
    except yaml.YAMLError as exc:
        return [f"unparsable YAML: {exc}"], []

    if not isinstance(entry, dict):
        return ["top level must be a mapping"], []

    # id <-> filename
    expected_id = path.stem
    if entry.get("id") != expected_id:
        errors.append(f"id '{entry.get('id')}' must equal filename '{expected_id}'")

    errors += check_required(entry, REQUIRED_TOP, "top")

    # status enum
    if "status" in entry and entry["status"] not in STATUSES:
        errors.append(f"status '{entry['status']}' not in {sorted(STATUSES)}")

    # nested requireds
    if isinstance(entry.get("problem"), dict):
        errors += check_required(entry["problem"], REQUIRED_PROBLEM, "problem")
    if isinstance(entry.get("solution"), dict):
        errors += check_required(entry["solution"], REQUIRED_SOLUTION, "solution")
    if isinstance(entry.get("repro"), dict):
        errors += check_required(entry["repro"], REQUIRED_REPRO, "repro")
        if not entry["repro"].get("nix"):
            warnings.append("no `repro.nix` hermetic check (NixOS-reader fast path missing)")
    else:
        errors.append("repro must be a mapping (the verifiability core)")

    # verifiability self-consistency
    if VALIDATED_SELF_CONSISTENCY and entry.get("status") == "verified":
        cc = entry.get("confirmation_count") or 0
        atts = entry.get("attestations") or []
        has_confirm = any(a.get("result") == "confirm" for a in atts if isinstance(a, dict))
        if cc < 1 and not has_confirm:
            errors.append(
                "status 'verified' requires confirmation_count>=1 OR a "
                "result:confirm attestation (you cannot prove what you cannot demonstrate)"
            )

    # license check
    if entry.get("provenance", {}).get("license", "CC0-1.0") != "CC0-1.0":
        warnings.append("license is not CC0-1.0; this limits redistribution freedom")

    # attestation result enum
    for a in entry.get("attestations") or []:
        if isinstance(a, dict) and a.get("result") not in RESULTS:
            errors.append(f"attestation result '{a.get('result')}' not in {sorted(RESULTS)}")

    return errors, warnings


def main():
    if len(sys.argv) > 1:
        paths = [Path(p) for p in sys.argv[1:]]
    else:
        paths = sorted(ENTRIES_DIR.glob("*.yaml"))
        if not paths:
            sys.exit("No entries found under entries/.")

    total_errs = total_warns = 0
    for p in paths:
        errors, warnings = validate_entry(p)
        total_errs += len(errors)
        total_warns += len(warnings)
        for w in warnings:
            print(f"WARN {p.name}: {w}")
        for e in errors:
            print(f"FAIL {p.name}: {e}")

    print(f"\n{len(paths)} entry file(s), {total_errs} error(s), {total_warns} warning(s)")
    sys.exit(1 if total_errs else 0)


if __name__ == "__main__":
    main()
