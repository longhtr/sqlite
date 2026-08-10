#!/usr/bin/env python3
"""Generate canonical Zig opcode identities and properties from pinned opcodes.h output."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
AMALGAMATION = ROOT / "reference/c_oracle/sqlite3.c"
VDBE_SOURCE = ROOT / "upstream/sqlite/src/vdbe.c"
OUTPUT = ROOT / "src/core/generated/opcodes.zig"
MANIFEST = ROOT / "generated/opcodes/manifest.json"
CHECKIN = "bf7c7f30031888f4e796e429ab3978879485813aaca6f641c7b33e4e09459bcc"


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def generate() -> tuple[str, dict]:
    source_bytes = AMALGAMATION.read_bytes()
    source = source_bytes.decode()
    definitions = [
        (name, int(value), comment or "")
        for name, value, comment in re.findall(
            r"^#define OP_(\w+)\s+(\d+)\s*(?:/\*\s*(.*?)\s*\*/)?$",
            source,
            re.MULTILINE,
        )
    ]
    definitions = [item for item in definitions if item[0] != "Max"]
    if len(definitions) != 192:
        raise SystemExit(f"unexpected opcode definition count: {len(definitions)}")
    definitions.sort(key=lambda item: item[1])
    if [value for _, value, _ in definitions] != list(range(len(definitions))):
        raise SystemExit("opcode values are not contiguous")

    initializer = re.search(
        r"#define OPFLG_INITIALIZER \{\\\n(.*?)\n\}", source, re.DOTALL
    )
    if initializer is None:
        raise SystemExit("OPFLG_INITIALIZER not found")
    properties = [int(value, 16) for value in re.findall(r"0x[0-9a-fA-F]+", initializer.group(1))]
    if len(properties) != len(definitions):
        raise SystemExit(f"opcode property count mismatch: {len(properties)}")
    max_jump_match = re.search(r"^#define SQLITE_MX_JUMP_OPCODE\s+(\d+)", source, re.MULTILINE)
    if max_jump_match is None:
        raise SystemExit("SQLITE_MX_JUMP_OPCODE not found")
    max_jump = int(max_jump_match.group(1))

    case_names = set(re.findall(r"case\s+OP_(\w+)\s*:", VDBE_SOURCE.read_text()))
    definition_names = {name for name, _, _ in definitions}
    if not case_names <= definition_names:
        raise SystemExit("vdbe.c contains an opcode case absent from opcodes.h")

    lines = [
        "//! Generated from the pinned SQLite opcodes.h section. Do not edit.",
        "",
        "pub const property = struct {",
        "    pub const jump: u8 = 0x01;",
        "    pub const in1: u8 = 0x02;",
        "    pub const in2: u8 = 0x04;",
        "    pub const in3: u8 = 0x08;",
        "    pub const out2: u8 = 0x10;",
        "    pub const out3: u8 = 0x20;",
        "    pub const ncycle: u8 = 0x40;",
        "    pub const jump0: u8 = 0x80;",
        "};",
        "",
        "pub const Opcode = enum(u8) {",
    ]
    for name, value, _ in definitions:
        lines.append(f"    {name} = {value},")
    lines += [
        "",
        "    pub fn flags(self: Opcode) u8 {",
        "        return properties[@intFromEnum(self)];",
        "    }",
        "};",
        "",
        f"pub const count: usize = {len(definitions)};",
        f"pub const execution_case_count: usize = {len(case_names)};",
        f"pub const max_jump_opcode: u8 = {max_jump};",
        "",
        "pub const properties = [count]u8{",
    ]
    for index in range(0, len(properties), 8):
        values = ", ".join(f"0x{value:02x}" for value in properties[index:index + 8])
        lines.append(f"    {values},")
    lines += [
        "};",
        "",
        "comptime {",
        "    if (@intFromEnum(Opcode.Abortable) + 1 != count) @compileError(\"opcode identity count mismatch\");",
        "    if (properties.len != count) @compileError(\"opcode property count mismatch\");",
        "    if (properties[max_jump_opcode] & property.jump == 0) @compileError(\"maximum jump opcode lacks jump property\");",
        "}",
        "",
    ]
    rendered = "\n".join(lines)
    output_bytes = rendered.encode()
    manifest = {
        "schema_version": 1,
        "sqlite_checkin": CHECKIN,
        "input": "reference/c_oracle/sqlite3.c opcodes.h section",
        "input_sha256": sha256_bytes(source_bytes),
        "vdbe_source_sha256": sha256_bytes(VDBE_SOURCE.read_bytes()),
        "output": "src/core/generated/opcodes.zig",
        "output_sha256": sha256_bytes(output_bytes),
        "opcode_count": len(definitions),
        "execution_case_count": len(case_names),
        "property_count": len(properties),
        "max_jump_opcode": max_jump,
        "non_execution_opcodes": sorted(definition_names - case_names),
    }
    return rendered, manifest


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    rendered, manifest = generate()
    manifest_text = json.dumps(manifest, indent=2) + "\n"
    if args.check:
        if not OUTPUT.is_file() or OUTPUT.read_text() != rendered:
            raise SystemExit("generated opcode Zig is stale; run tools/generate_opcodes.py")
        if not MANIFEST.is_file() or MANIFEST.read_text() != manifest_text:
            raise SystemExit("generated opcode manifest is stale; run tools/generate_opcodes.py")
        print(f"opcodes: verified {manifest['opcode_count']} identities and properties")
        return
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    MANIFEST.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(rendered)
    MANIFEST.write_text(manifest_text)
    print(f"opcodes: generated {manifest['opcode_count']} identities and properties")


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
