#!/usr/bin/env python3
"""Mutation-test fail-closed translation tracking and explicit promotion behavior."""

from __future__ import annotations

import copy
import json
import pathlib
import tempfile
from collections.abc import Callable

import port_batch_gate as gate

ROOT = pathlib.Path(__file__).resolve().parent.parent


def expect_failure(fragment: str, action: Callable[[], object]) -> None:
    try:
        action()
    except SystemExit as error:
        if fragment not in str(error):
            raise SystemExit(
                f"port-batch mutation failed for the wrong reason: {error}"
            ) from error
        return
    raise SystemExit(f"port-batch mutation unexpectedly passed: {fragment}")


def main() -> None:
    original_manifest = gate.MANIFEST
    original_historical = gate.HISTORICAL_CLAIMS
    original_checkpoints = gate.CHECKPOINTS
    manifest = json.loads(original_manifest.read_text())
    historical = json.loads(original_historical.read_text())
    checkpoints = json.loads(original_checkpoints.read_text())
    scratch = ROOT / "tmp"
    scratch.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="port-batch-gate-", dir=scratch) as temporary:
        directory = pathlib.Path(temporary)
        manifest_path = directory / "active-port-batch.json"
        historical_path = directory / "historical-port-claims.json"
        checkpoints_path = directory / "port-checkpoints.json"
        manifest["historical_claim_ledger"] = historical_path.relative_to(ROOT).as_posix()
        gate.MANIFEST = manifest_path
        gate.HISTORICAL_CLAIMS = historical_path
        gate.CHECKPOINTS = checkpoints_path
        try:
            historical_path.write_text(json.dumps(historical))
            checkpoints_path.write_text(json.dumps(checkpoints))

            def check_mutation(value: dict[str, object], fragment: str) -> None:
                manifest_path.write_text(json.dumps(value))
                expect_failure(fragment, gate.validate)

            mutated = copy.deepcopy(manifest)
            mutated["status"] = "disabled"
            check_mutation(mutated, "unknown active manifest status")

            mutated = copy.deepcopy(manifest)
            mutated["entries"] = [historical["entries"][0]]
            check_mutation(mutated, "idle active manifest contains entries")

            mutated = copy.deepcopy(manifest)
            mutated["status"] = "active"
            check_mutation(mutated, "active manifest contains no entries")

            mutated = copy.deepcopy(manifest)
            mutated["minimum_substantive_functions"] = 49
            check_mutation(mutated, "substantive-function threshold was weakened")

            mutated_historical = copy.deepcopy(historical)
            claims = mutated_historical["entries"]
            claims.append(copy.deepcopy(claims[0]))
            mutated_historical["short_functions"] += 1
            historical_path.write_text(json.dumps(mutated_historical))
            manifest_path.write_text(json.dumps(manifest))
            expect_failure("historical mechanical claims contain duplicate source IDs", gate.validate)
            historical_path.write_text(json.dumps(historical))

            bad_checkpoints = copy.deepcopy(checkpoints)
            bad_checkpoints["checkpoints"] = [{
                "id": "invalid-checkpoint",
                "parent_checkpoint_id": None,
                "git_commit": "not-a-commit",
                "entries": [],
                "short_functions": 0,
                "substantive_functions": 0,
                "evidence_receipts": [],
                "translation_credit": True,
            }]
            checkpoints_path.write_text(json.dumps(bad_checkpoints))
            manifest_path.write_text(json.dumps(manifest))
            expect_failure("checkpoint lacks an exact Git commit", gate.validate)

            checkpoints_path.write_text(json.dumps(checkpoints))
            manifest_path.write_text(json.dumps(manifest))
            expect_failure("checkpoint promotion requires an active batch", gate.require_checkpoint_ready)
        finally:
            gate.MANIFEST = original_manifest
            gate.HISTORICAL_CLAIMS = original_historical
            gate.CHECKPOINTS = original_checkpoints
    print("test-port-batch-gate: fail-closed mutations and idle promotion rejection passed")


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
