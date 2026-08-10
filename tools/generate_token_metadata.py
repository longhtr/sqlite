#!/usr/bin/env python3
"""Generate Zig token, keyword, and fallback metadata from pinned parser outputs."""

from __future__ import annotations

import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent


def main() -> None:
    header = (ROOT / "generated/parser/sqlite_parse.h").read_text()
    pairs = [
        (name, int(value))
        for name, value in re.findall(r"#define TK_(\w+)\s+(\d+)", header)
    ]
    tokens = ["//! Generated from the pinned Lemon token header.", ""]
    for name, value in pairs:
        tokens.append(f"pub const tk_{name.lower()}: u16 = {value};")
    tokens += ["", f"pub const max_token: u16 = {max(value for _, value in pairs)};", ""]
    (ROOT / "src/core/generated/tokens.zig").write_text("\n".join(tokens))

    source = (ROOT / "reference/c_oracle/sqlite3.c").read_text()
    start = source.index("static const unsigned char aKWCode[148]")
    body = source[source.index("{", start) + 1 : source.index("};", start)]
    codes = re.findall(r"TK_(\w+)", body)
    keyword_start = source.index("static i64 keywordCode(", start)
    keyword_end = source.index("*pType = aKWCode[i];", keyword_start)
    names = re.findall(
        r"testcase\( i==\d+ \); /\* ([A-Z_]+) \*/",
        source[keyword_start:keyword_end],
    )
    if len(names) != 147 or len(codes) != 147:
        raise SystemExit(f"unexpected keyword metadata: {len(names)}, {len(codes)}")
    values = dict(pairs)
    keywords = [
        "//! Generated keyword/token mapping from pinned `keywordhash.h`.",
        "",
        "pub const Entry = struct { name: []const u8, token: u16 };",
        "pub const entries = [_]Entry{",
    ]
    for name, code in zip(names, codes):
        keywords.append(f'    .{{ .name = "{name}", .token = {values[code]} }},')
    keywords += ["};", ""]
    (ROOT / "src/core/generated/keywords.zig").write_text("\n".join(keywords))

    fallback_start = source.index("static const YYCODETYPE yyFallback[]")
    fallback_body = source[
        source.index("{", fallback_start) + 1 : source.index("};", fallback_start)
    ]
    fallback_body = re.sub(r"/\*.*?\*/", "", fallback_body, flags=re.S)
    fallback_values = [int(value) for value in re.findall(r"\b\d+\b", fallback_body)]
    fallback = [
        "//! Generated fallback-to-ID flags from pinned Lemon parser.",
        "",
        "pub const to_id = [_]bool{",
    ]
    fallback += [f'    {str(value == values["ID"]).lower()},' for value in fallback_values]
    fallback += ["};", ""]
    (ROOT / "src/core/generated/fallback.zig").write_text("\n".join(fallback))


if __name__ == "__main__":
    from port_batch_gate import require_ready

    require_ready()
    main()
