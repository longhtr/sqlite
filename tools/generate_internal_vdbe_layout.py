#!/usr/bin/env python3
"""Generate C-oracle layout facts for active vdbe.h structures."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import bounded_subprocess as subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROFILE = json.loads((ROOT / "upstream/SQLITE_BUILD_PROFILE.json").read_text())
PROBE = ROOT / "reference/c_oracle/internal_vdbe_layout.c"
AMALGAMATION = ROOT / "reference/c_oracle/sqlite3.c"
ZIG_OUTPUT = ROOT / "src/core/generated/internal_vdbe_layout.zig"
MANIFEST = ROOT / "generated/internal/vdbe-layout.json"

TYPE_NAMES = {
    "Vdbe": "Vdbe",
    "VdbeCursor": "VdbeCursor",
    "sqlite3_pcache_methods2": "PcacheMethods2",
    "struct Sqlite3Config": "Sqlite3Config",
    "struct sqlite3InitInfo": "Sqlite3InitInfo",
    "Sqlite3Trace": "Sqlite3Trace",
    "Sqlite3Interrupt": "Sqlite3Interrupt",
    "sqlite3": "Sqlite3",
    "BusyHandler": "BusyHandler",
    "BtLock": "BtLock",
    "BtreePayload": "BtreePayload",
    "Btree": "Btree",
    "Db": "Db",
    "Schema": "Schema",
    "Column": "Column",
    "Table": "Table",
    "Index": "Index",
    "FKey": "FKey",
    "struct _ht": "HashBucket",
    "HashElem": "HashElem",
    "Hash": "Hash",
    "LookasideSlot": "LookasideSlot",
    "Lookaside": "Lookaside",
    "CollSeq": "CollSeq",
    "FuncDestructor": "FuncDestructor",
    "FuncDef": "FuncDef",
    "FuncDefHash": "FuncDefHash",
    "Savepoint": "Savepoint",
    "Module": "Module",
    "DbClientData": "DbClientData",
    "KeyInfo": "KeyInfo",
    "UnpackedRecord": "UnpackedRecord",
    "PreUpdate": "PreUpdate",
    "union MemValue": "MemValue",
    "Mem": "Mem",
    "VdbeTxtBlbCache": "VdbeTxtBlbCache",
    "VdbeFrame": "VdbeFrame",
    "AuxData": "AuxData",
    "sqlite3_context": "Context",
    "ScanStatus": "ScanStatus",
    "DblquoteStr": "DblquoteStr",
    "ValueList": "ValueList",
    "SubrtnSig": "SubrtnSig",
    "union p4union": "P4Union",
    "VdbeOp": "VdbeOp",
    "SubProgram": "SubProgram",
    "VdbeOpList": "VdbeOpList",
}


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def generate() -> tuple[str, dict]:
    compiler = PROFILE["oracle"]["production_compiler"]["path"]
    defines = [
        f"-D{name}={value}"
        for name, value in PROFILE["configure"]["library_defines"].items()
    ]
    with tempfile.TemporaryDirectory(prefix="sqlite-zig-internal-vdbe-layout-") as temp:
        executable = pathlib.Path(temp) / "probe"
        subprocess.run([
            compiler, "-std=c11", "-O0", *defines, str(PROBE),
            "-lm", "-lz", "-ldl", "-o", str(executable),
        ], check=True)
        output = subprocess.check_output([str(executable)], text=True)

    types: dict[str, dict] = {}
    constants: dict[str, int] = {}
    for line in output.splitlines():
        fields = line.split("\t")
        if fields[0] == "TYPE":
            _, name, size, alignment = fields
            types[name] = {"size": int(size), "alignment": int(alignment), "fields": {}}
        elif fields[0] == "FIELD":
            _, name, field, offset, size = fields
            types[name]["fields"][field] = {"offset": int(offset), "size": int(size)}
        elif fields[0] == "CONST":
            _, name, value = fields
            constants[name] = int(value)
        else:
            raise SystemExit(f"unexpected layout probe output: {line}")
    if set(types) != set(TYPE_NAMES):
        raise SystemExit(f"layout type set mismatch: {set(types)}")

    lines = ["//! Generated C-oracle layout facts for active vdbe.h types. Do not edit.", ""]
    for c_name, zig_name in TYPE_NAMES.items():
        item = types[c_name]
        lines += [
            f"pub const {zig_name} = struct {{",
            f"    pub const size: usize = {item['size']};",
            f"    pub const alignment: usize = {item['alignment']};",
        ]
        for field, fact in item["fields"].items():
            lines += [
                f"    pub const {field}_offset: usize = {fact['offset']};",
                f"    pub const {field}_size: usize = {fact['size']};",
            ]
        lines += ["};", ""]
    lines.append("pub const constants = struct {")
    for name, value in constants.items():
        lines.append(f"    pub const {name}: i64 = {value};")
    lines += ["};", ""]
    rendered = "\n".join(lines)
    manifest = {
        "schema_version": 1,
        "sqlite_checkin": PROFILE["baseline_checkin"],
        "profile": PROFILE["profile_id"],
        "compiler": {
            "path": compiler,
            "driver_sha256": PROFILE["oracle"]["production_compiler"]["driver_sha256"],
            "target": subprocess.check_output([compiler, "-dumpmachine"], text=True).strip(),
        },
        "inputs": {
            "probe": PROBE.relative_to(ROOT).as_posix(),
            "probe_sha256": sha256(PROBE),
            "amalgamation": AMALGAMATION.relative_to(ROOT).as_posix(),
            "amalgamation_sha256": sha256(AMALGAMATION),
        },
        "output": ZIG_OUTPUT.relative_to(ROOT).as_posix(),
        "types": types,
        "constants": constants,
    }
    manifest["output_sha256"] = hashlib.sha256(rendered.encode()).hexdigest()
    return rendered, manifest


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    rendered, manifest = generate()
    manifest_text = json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    if args.check:
        if not ZIG_OUTPUT.is_file() or ZIG_OUTPUT.read_text() != rendered:
            raise SystemExit("internal VDBE Zig layout facts are stale")
        if not MANIFEST.is_file() or MANIFEST.read_text() != manifest_text:
            raise SystemExit("internal VDBE layout manifest is stale")
        print(f"internal-vdbe-layout: verified {len(manifest['types'])} active C layouts")
        return
    ZIG_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    MANIFEST.parent.mkdir(parents=True, exist_ok=True)
    ZIG_OUTPUT.write_text(rendered)
    MANIFEST.write_text(manifest_text)
    print(f"internal-vdbe-layout: generated {len(manifest['types'])} active C layouts")


if __name__ == "__main__":
    main()
