#!/usr/bin/env python3
"""Refresh hashes for AST-resolved legacy candidates after native code changes.

Legacy candidates are not reviewed mappings or fidelity evidence. Reviewed mapping
hashes are intentionally never changed by this tool.
"""

from __future__ import annotations

import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
LEDGER = ROOT / "upstream/symbol-map.json"


def main() -> None:
    ledger = json.loads(LEDGER.read_text())
    declarations = {
        item["id"]: item
        for item in json.loads(
            (ROOT / "upstream/zig-declaration-inventory.json").read_text()
        )["declarations"]
    }
    refreshed = 0
    for entry in ledger["entities"]:
        if not entry["classification"].startswith("legacy-candidate-"):
            continue
        for target in entry.get("zig", []):
            declaration = declarations.get(target["declaration_id"])
            if declaration is None:
                raise SystemExit(
                    "legacy target declaration disappeared; review it manually: "
                    f"{target['declaration_id']}"
                )
            if target["source_sha256"] != declaration["source_sha256"]:
                target["source_sha256"] = declaration["source_sha256"]
                refreshed += 1
    LEDGER.write_text(json.dumps(ledger, indent=2) + "\n")
    print(f"refreshed {refreshed} legacy target hashes")


if __name__ == "__main__":
    main()
