#!/usr/bin/env python3
"""Post-process quicktype Swift output for public SwiftPM consumption."""

from __future__ import annotations

import re
import sys
from datetime import datetime, timezone

ROOT_TYPE = "CodexProtocolRoot"


def remove_block(lines: list[str], start_index: int) -> int:
    depth = 0
    index = start_index
    while index < len(lines):
        for character in lines[index]:
            if character == "{":
                depth += 1
            elif character == "}":
                depth -= 1
        lines[index] = None  # type: ignore[assignment]
        index += 1
        if depth <= 0:
            break
    return index


def main() -> int:
    if len(sys.argv) != 5:
        print(
            "usage: postprocess-swift.py <input> <output> <codex-version> <installed-version>",
            file=sys.stderr,
        )
        return 1

    input_file, output_file, codex_version, installed_version = sys.argv[1:5]

    with open(input_file) as handle:
        lines = handle.readlines()

    for index, line in enumerate(lines):
        if line.startswith("import Foundation"):
            break
        lines[index] = None  # type: ignore[assignment]

    index = 0
    while index < len(lines):
        line = lines[index]
        if line is None:
            index += 1
            continue
        stripped = line.strip()
        if stripped in {
            f"// MARK: - {ROOT_TYPE}",
            f"// MARK: {ROOT_TYPE} convenience initializers and mutators",
        }:
            lines[index] = None  # type: ignore[assignment]
            index += 1
            continue
        if re.match(rf"^struct {ROOT_TYPE}\b", stripped) or re.match(rf"^extension {ROOT_TYPE}\b", stripped):
            index = remove_block(lines, index)
            continue
        index += 1

    content = "".join(line for line in lines if line is not None)
    content = content.replace("internal ", "public ")
    content = content.replace(
        "class JSONCodingKey: CodingKey",
        "final class JSONCodingKey: CodingKey",
    )
    content = content.replace(
        "class JSONAny: Codable",
        "final class JSONAny: Codable, @unchecked Sendable",
    )
    content = content.replace(
        "class JSONNull: Codable",
        "final class JSONNull: Codable, @unchecked Sendable",
    )
    content = content.replace(
        "func newJSONDecoder() -> JSONDecoder {",
        "public func newJSONDecoder() -> JSONDecoder {",
    )
    content = content.replace(
        "func newJSONEncoder() -> JSONEncoder {",
        "public func newJSONEncoder() -> JSONEncoder {",
    )
    content = content.replace(
        "public var hashValue: Int {\n            return 0\n    }",
        "public func hash(into hasher: inout Hasher) {}",
    )
    content = re.sub(r"\n{4,}", "\n\n\n", content)

    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    header = f"""// GENERATED CODE — DO NOT EDIT
//
// Source: codex app-server generate-json-schema --experimental
// Codex version: {codex_version} ({installed_version})
// Generated at: {generated_at}
//
// To regenerate: ./Scripts/generate-protocol.sh
//

"""

    with open(output_file, "w") as handle:
        handle.write(header)
        handle.write(content)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
