#!/usr/bin/env python3
"""Generate typed Swift bridge files from codex TypeScript protocol unions."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


REQUEST_RESPONSE_OVERRIDES = {
    "account/login/start": "LoginAccountResponse",
    "account/login/cancel": "CancelLoginAccountResponse",
    "account/logout": "LogoutAccountResponse",
    "account/rateLimits/read": "GetAccountRateLimitsResponse",
    "app/list": "AppsListResponse",
    "config/batchWrite": "ConfigWriteResponse",
    "config/mcpServer/reload": "McpServerRefreshResponse",
    "config/value/write": "ConfigWriteResponse",
    "mcpServerStatus/list": "ListMcpServerStatusResponse",
}


def pascal(camel: str) -> str:
    return camel[0].upper() + camel[1:]


def candidate_names(base: str) -> list[str]:
    names = [base]
    if base.startswith("Fs"):
        names.append("FS" + base[2:])
    if base.startswith("Mcp"):
        names.append("MCP" + base[3:])
    return names


def resolve_swift_type(type_name: str, swift_types: set[str]) -> str | None:
    candidates: list[str] = []
    for raw_name in (type_name, f"CodexProtocolRoot{type_name}"):
        for candidate in candidate_names(raw_name):
            if candidate not in candidates:
                candidates.append(candidate)
    for candidate in candidates:
        if candidate in swift_types:
            return candidate
    return None


def collect_swift_types(swift_text: str) -> set[str]:
    pattern = re.compile(r"^(?:public\s+)?(?:struct|class|enum|typealias)\s+(\w+)", re.MULTILINE)
    return set(pattern.findall(swift_text))


def collect_method_cases(swift_text: str, enum_name: str) -> list[tuple[str, str]]:
    match = re.search(rf"enum {enum_name}[^{{]*\{{(.*?)\n\}}", swift_text, re.DOTALL)
    if not match:
        raise RuntimeError(f"{enum_name} enum not found in generated Swift")
    return re.findall(r'case\s+(\w+)\s*=\s*"([^"]+)"', match.group(1))


def parse_union_with_params(ts_text: str, union_name: str, has_id: bool) -> dict[str, str | None]:
    match = re.search(rf"export type {union_name}\s*=\s*(.*);", ts_text, re.DOTALL)
    if not match:
        raise RuntimeError(f"{union_name} union not found")
    if has_id:
        entries = re.findall(
            r'\{\s*"method":\s*"([^"]+)",\s*id:\s*[^,]+,\s*params:\s*([^,]+),\s*\}',
            match.group(1),
        )
    else:
        entries = re.findall(
            r'\{\s*"method":\s*"([^"]+)",\s*"params":\s*([^,}]+)\s*\}',
            match.group(1),
        )
    result: dict[str, str | None] = {}
    for method, params in entries:
        params = params.strip()
        result[method] = None if params == "undefined" else params
    return result


def infer_response_name(method: str, params_type_name: str | None) -> str:
    override = REQUEST_RESPONSE_OVERRIDES.get(method)
    if override is not None:
        return override
    if params_type_name and params_type_name.endswith("Params"):
        return f"{params_type_name[:-6]}Response"
    base = "".join(part[:1].upper() + part[1:] for part in re.split(r"[/_-]", method))
    return f"{base}Response"


def load_schema_definitions(path: Path) -> dict[str, object]:
    with path.open() as handle:
        return json.load(handle).get("definitions", {})


def description_for_type(definitions: dict[str, object], type_name: str | None) -> str | None:
    """Return the schema description for ``type_name`` if one exists."""
    if not type_name:
        return None
    schema = _lookup_definition(definitions, type_name)
    if schema is None:
        return None
    desc = schema.get("description")
    if isinstance(desc, str) and desc.strip():
        return desc.strip()
    return None


def format_doc_block(description: str, indent: str) -> list[str]:
    text = description.replace("\r\n", "\n").replace("\r", "\n").strip()
    # See postprocess-swift.format_doc_comment — downgrade triple backticks
    # to inline code so DocC's Markdown parser doesn't see an unclosed fence
    # when the description gets split across multiple `///` lines.
    text = text.replace("```", "`")
    lines: list[str] = []
    for raw in text.split("\n"):
        stripped = raw.rstrip()
        if stripped:
            lines.append(f"{indent}/// {stripped}")
        else:
            lines.append(f"{indent}///")
    return lines


def _lookup_definition(definitions: dict[str, object], name: str) -> dict | None:
    candidates = [name, f"CodexProtocolRoot{name}"]
    for candidate in candidates:
        schema = definitions.get(candidate)
        if isinstance(schema, dict):
            return schema
    for subtree_key in ("v2", "v1"):
        subtree = definitions.get(subtree_key)
        if not isinstance(subtree, dict):
            continue
        for candidate in candidates:
            schema = subtree.get(candidate)
            if isinstance(schema, dict):
                return schema
    return None


def is_empty_object_type(definitions: dict[str, object], type_name: str | None) -> bool:
    if type_name is None:
        return False
    schema = _lookup_definition(definitions, type_name)
    if schema is None:
        return False
    return schema.get("type") == "object" and not schema.get("properties") and not schema.get("required")


def definition_exists(definitions: dict[str, object], type_name: str | None) -> bool:
    if type_name is None:
        return False
    return _lookup_definition(definitions, type_name) is not None


def write_rpc_bridge(
    swift_text: str,
    client_request_ts: str,
    schema_definitions: dict[str, object],
    out_path: Path,
) -> None:
    swift_types = collect_swift_types(swift_text)
    methods = collect_method_cases(swift_text, "ClientRequestMethod")
    ts_mapping = parse_union_with_params(client_request_ts, "ClientRequest", has_id=True)

    lines = [
        "// GENERATED BY Scripts/generate-swift-bridge.py — DO NOT EDIT.",
        "",
        "import Foundation",
        "",
        "extension RPC {",
    ]

    sorted_methods = sorted(methods, key=lambda entry: pascal(entry[0]))
    method_cases: list[str] = []

    for enum_case, wire_method in sorted_methods:
        params_type_name = ts_mapping.get(wire_method)
        if wire_method not in ts_mapping:
            raise RuntimeError(f"client request method {wire_method!r} missing from TS union")
        params_type = "EmptyParams" if params_type_name is None else resolve_swift_type(params_type_name, swift_types)
        if params_type is None and is_empty_object_type(schema_definitions, params_type_name):
            params_type = "EmptyParams"
        if params_type is None:
            raise RuntimeError(f"unable to resolve Swift params type for {wire_method!r}: {params_type_name}")
        response_type_name = infer_response_name(wire_method, params_type_name)
        response_type = resolve_swift_type(response_type_name, swift_types)
        if response_type is None and is_empty_object_type(schema_definitions, response_type_name):
            response_type = "EmptyResponse"
        if response_type is None:
            raise RuntimeError(
                f"unable to resolve Swift response type for {wire_method!r}: {response_type_name}"
            )

        description = (
            description_for_type(schema_definitions, params_type_name)
            or description_for_type(schema_definitions, response_type_name)
        )
        doc_lines: list[str] = []
        if description:
            doc_lines.extend(format_doc_block(description, "    "))
            doc_lines.append("    ///")
        doc_lines.append(f"    /// Wire method: `{wire_method}`.")

        lines.extend(doc_lines)
        lines.extend(
            [
                f"    public enum {pascal(enum_case)}: CodexRPCMethod {{",
                f"        public typealias Params = {params_type}",
                f"        public typealias Response = {response_type}",
                f"        public static let method = ClientRequestMethod.{enum_case}",
                "    }",
                "",
            ]
        )
        method_cases.append(pascal(enum_case))

    if lines[-1] == "":
        lines.pop()
    lines.append("}")
    lines.append("")
    lines.extend(
        [
            "extension RPC {",
            "    /// All RPC methods exposed by this Codex binding, in a stable order.",
            "    ///",
            "    /// Useful for documentation tooling, method-name allow-lists, and debug UIs",
            "    /// that need to enumerate the full client-to-server surface without switching",
            "    /// on individual method types.",
            "    public static let allMethods: [any CodexRPCMethod.Type] = [",
        ]
    )
    for base_name in method_cases:
        lines.append(f"        RPC.{base_name}.self,")
    lines.extend(["    ]", "}", ""])
    out_path.write_text("\n".join(lines))


def write_server_notifications(
    swift_text: str,
    server_notification_ts: str,
    schema_definitions: dict[str, object],
    out_path: Path,
) -> None:
    swift_types = collect_swift_types(swift_text)
    methods = collect_method_cases(swift_text, "NotificationMethod")
    ts_mapping = parse_union_with_params(server_notification_ts, "ServerNotification", has_id=False)

    entries: list[tuple[str, str, str, str, str | None]] = []
    for enum_case, wire_method in methods:
        if wire_method not in ts_mapping:
            raise RuntimeError(f"server notification {wire_method!r} missing from TS union")
        params_type_name = ts_mapping[wire_method]
        if params_type_name is None:
            raise RuntimeError(f"server notification {wire_method!r} unexpectedly has no params")
        params_type = resolve_swift_type(params_type_name, swift_types)
        if params_type is None and is_empty_object_type(schema_definitions, params_type_name):
            params_type = "EmptyResponse"
        if params_type is None:
            raise RuntimeError(f"unable to resolve Swift params type for {wire_method!r}: {params_type_name}")
        description = description_for_type(schema_definitions, params_type_name)
        entries.append((enum_case, pascal(enum_case), params_type, wire_method, description))

    lines = [
        "// GENERATED BY Scripts/generate-swift-bridge.py — DO NOT EDIT.",
        "",
        "import Foundation",
        "",
        "extension ServerNotifications {",
    ]

    for enum_case, base_name, params_type, wire_method, description in entries:
        if description:
            lines.extend(format_doc_block(description, "    "))
            lines.append("    ///")
        lines.append(f"    /// Wire method: `{wire_method}`.")
        lines.extend(
            [
                f"    public enum {base_name}: CodexServerNotificationMethod {{",
                f"        public typealias Params = {params_type}",
                f"        public static let method = NotificationMethod.{enum_case}",
                "    }",
                "",
            ]
        )

    lines.extend(
        [
            "}",
            "",
            "/// All server notification methods exposed by this Codex binding, in wire order.",
            "///",
            "/// Mirrors ``RPC/allMethods``. Useful for validation, docs, or building UIs that",
            "/// want to surface the full notification surface without hard-coding case names.",
            "extension ServerNotifications {",
            "    public static let all: [any CodexServerNotificationMethod.Type] = [",
        ]
    )
    for _, base_name, _, _, _ in entries:
        lines.append(f"        ServerNotifications.{base_name}.self,")
    lines.extend(["    ]", "}", ""])

    lines.extend(
        [
            "/// A single server-to-client notification, carrying its typed params payload.",
            "///",
            "/// Emitted through `CodexClient.events(bufferSize:)` wrapped in `CodexEvent.notification(_:)`.",
            "/// Use ``ServerNotificationEvent/method`` to identify the notification type without",
            "/// exhaustively switching on every case — handy for logging and diagnostics.",
            "public enum ServerNotificationEvent: Sendable {",
        ]
    )

    for enum_case, _, params_type, _, _ in entries:
        lines.append(f"    case {enum_case}({params_type})")

    lines.extend(
        [
            "",
            "    /// The notification method identifier, without having to exhaustively switch",
            "    /// on each case. Convenient for logging (`print(event.method.rawValue)`).",
            "    public var method: NotificationMethod {",
            "        switch self {",
        ]
    )

    for enum_case, _, _, _, _ in entries:
        lines.append(f"        case .{enum_case}: return .{enum_case}")

    lines.extend(
        [
            "        }",
            "    }",
            "",
            "    public init(from data: Data) throws {",
            "        try self.init(from: data, decoder: newJSONDecoder())",
            "    }",
            "",
            "    public init(from data: Data, decoder: JSONDecoder) throws {",
            "        let envelope = try decoder.decode(_ServerNotificationEnvelope.self, from: data)",
            "        switch envelope.method {",
        ]
    )

    for enum_case, _, params_type, _, _ in entries:
        lines.extend(
            [
                f"        case .{enum_case}:",
                f"            self = .{enum_case}(try decoder.decode(_ServerNotificationPayload<{params_type}>.self, from: data).params)",
            ]
        )

    lines.extend(
        [
            "        }",
            "    }",
            "}",
            "",
            "private struct _ServerNotificationEnvelope: Decodable {",
            "    let method: NotificationMethod",
            "}",
            "",
            "private struct _ServerNotificationPayload<Params: Decodable>: Decodable {",
            "    let params: Params",
            "}",
            "",
        ]
    )

    out_path.write_text("\n".join(lines))


def write_server_requests(
    swift_text: str,
    server_request_ts: str,
    schema_definitions: dict[str, object],
    out_path: Path,
) -> None:
    swift_types = collect_swift_types(swift_text)
    methods = collect_method_cases(swift_text, "ServerRequestMethod")
    ts_mapping = parse_union_with_params(server_request_ts, "ServerRequest", has_id=True)

    entries: list[tuple[str, str, str, str, str, str | None]] = []
    for enum_case, wire_method in methods:
        if wire_method not in ts_mapping:
            raise RuntimeError(f"server request {wire_method!r} missing from TS union")
        params_type_name = ts_mapping[wire_method]
        if params_type_name is None:
            raise RuntimeError(f"server request {wire_method!r} unexpectedly has no params")
        params_type = resolve_swift_type(params_type_name, swift_types)
        if params_type is None and is_empty_object_type(schema_definitions, params_type_name):
            params_type = "EmptyParams"
        if params_type is None:
            raise RuntimeError(f"unable to resolve Swift params type for {wire_method!r}: {params_type_name}")
        response_type_name = infer_response_name(wire_method, params_type_name)
        response_type = resolve_swift_type(response_type_name, swift_types)
        if response_type is None and is_empty_object_type(schema_definitions, response_type_name):
            response_type = "EmptyResponse"
        if response_type is None:
            raise RuntimeError(
                f"unable to resolve Swift response type for {wire_method!r}: {response_type_name}"
            )
        description = (
            description_for_type(schema_definitions, params_type_name)
            or description_for_type(schema_definitions, response_type_name)
        )
        entries.append((enum_case, pascal(enum_case), params_type, response_type, wire_method, description))

    lines = [
        "// GENERATED BY Scripts/generate-swift-bridge.py — DO NOT EDIT.",
        "",
        "import Foundation",
        "",
        "extension ServerRequests {",
    ]

    for enum_case, base_name, params_type, response_type, wire_method, description in entries:
        if description:
            lines.extend(format_doc_block(description, "    "))
            lines.append("    ///")
        lines.append(f"    /// Wire method: `{wire_method}`.")
        lines.extend(
            [
                f"    public enum {base_name}: CodexServerRequestMethod {{",
                f"        public typealias Params = {params_type}",
                f"        public typealias Response = {response_type}",
                f"        public static let method = ServerRequestMethod.{enum_case}",
                "    }",
                "",
            ]
        )

    lines.extend(
        [
            "}",
            "",
            "/// All server request methods exposed by this Codex binding, in wire order.",
            "///",
            "/// Mirrors ``RPC/allMethods``. Handy for building approval/consent UIs that",
            "/// need to enumerate every inbound request type the server can send.",
            "extension ServerRequests {",
            "    public static let all: [any CodexServerRequestMethod.Type] = [",
        ]
    )
    for _, base_name, _, _, _, _ in entries:
        lines.append(f"        ServerRequests.{base_name}.self,")
    lines.extend(["    ]", "}", ""])

    lines.extend(
        [
            "/// A type-erased server-to-client request carrying its payload.",
            "///",
            "/// Surfaced through `CodexClient.events(bufferSize:)` wrapped in `CodexEvent.serverRequest(_:)`.",
            "/// Respond with `CodexClient.respond(to:result:)` or `CodexClient.reject(_:code:message:)`.",
            "public enum AnyTypedServerRequest: Sendable {",
        ]
    )

    for enum_case, _, _, _, _, _ in entries:
        lines.append(f"    case {enum_case}(TypedServerRequest<ServerRequests.{pascal(enum_case)}>)")

    lines.extend(
        [
            "",
            "    /// The JSON-RPC request identifier assigned by the server.",
            "    public var id: RequestId {",
            "        switch self {",
        ]
    )

    for enum_case, _, _, _, _, _ in entries:
        lines.append(f"        case .{enum_case}(let request): return request.id")

    lines.extend(
        [
            "        }",
            "    }",
            "",
            "    /// Identifies which request method the server sent, without exhaustively",
            "    /// unwrapping each case.",
            "    public var method: ServerRequestMethod {",
            "        switch self {",
        ]
    )

    for enum_case, _, _, _, _, _ in entries:
        lines.append(f"        case .{enum_case}: return .{enum_case}")

    lines.extend(
        [
            "        }",
            "    }",
            "",
            "    public init(from data: Data) throws {",
            "        try self.init(from: data, decoder: newJSONDecoder())",
            "    }",
            "",
            "    public init(from data: Data, decoder: JSONDecoder) throws {",
            "        let envelope = try decoder.decode(_ServerRequestEnvelope.self, from: data)",
            "        switch envelope.method {",
        ]
    )

    for enum_case, _, params_type, _, _, _ in entries:
        lines.extend(
            [
                f"        case .{enum_case}:",
                f"            let payload = try decoder.decode(_ServerRequestPayload<{params_type}>.self, from: data)",
                f"            self = .{enum_case}(TypedServerRequest<ServerRequests.{pascal(enum_case)}>(id: payload.id, params: payload.params))",
            ]
        )

    lines.extend(
        [
            "        }",
            "    }",
            "}",
            "",
            "private struct _ServerRequestEnvelope: Decodable {",
            "    let method: ServerRequestMethod",
            "}",
            "",
            "private struct _ServerRequestPayload<Params: Decodable>: Decodable {",
            "    let id: RequestId",
            "    let params: Params",
            "}",
            "",
        ]
    )

    out_path.write_text("\n".join(lines))


def write_metadata(out_path: Path, codex_version: str) -> None:
    out_path.write_text(
        "\n".join(
            [
                "// GENERATED BY Scripts/generate-swift-bridge.py — DO NOT EDIT.",
                "",
                "import Foundation",
                "",
                "public enum CodexBindingMetadata {",
                f'    public static let codexVersion = "{codex_version}"',
                "    public static let includesExperimentalAPI = true",
                "}",
                "",
            ]
        )
    )


def category_for_wire_method(wire_method: str) -> str:
    """Group wire methods by their first path segment for catalog organisation."""
    if "/" in wire_method:
        return wire_method.split("/", 1)[0]
    return "core"


def write_catalog_article(
    out_path: Path,
    title: str,
    intro: str,
    namespace: str,
    entries: list[tuple[str, str]],  # (base_name, wire_method)
) -> None:
    """Emit a DocC article that groups all generated symbols of a kind by category."""
    by_category: dict[str, list[tuple[str, str]]] = {}
    for base_name, wire_method in sorted(entries, key=lambda e: e[1]):
        by_category.setdefault(category_for_wire_method(wire_method), []).append(
            (base_name, wire_method)
        )

    lines: list[str] = [
        f"# {title}",
        "",
        intro,
        "",
        "## Topics",
        "",
    ]
    for category in sorted(by_category):
        category_label = category if category != "core" else "Core"
        lines.append(f"### {category_label}")
        lines.append("")
        for base_name, _wire_method in by_category[category]:
            lines.append(f"- ``{namespace}/{base_name}``")
        lines.append("")

    out_path.write_text("\n".join(lines))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--swift", required=True, type=Path)
    parser.add_argument("--client-request-ts", required=True, type=Path)
    parser.add_argument("--server-notification-ts", required=True, type=Path)
    parser.add_argument("--server-request-ts", required=True, type=Path)
    parser.add_argument("--schema", required=True, type=Path)
    parser.add_argument("--out-dir", required=True, type=Path)
    parser.add_argument("--docc-out-dir", required=True, type=Path,
                        help="Directory to write generated DocC catalog articles into.")
    parser.add_argument("--codex-version", required=True)
    return parser


def collect_methods_for_catalog(swift_text: str, enum_name: str) -> list[tuple[str, str]]:
    """Return [(PascalCaseBaseName, wireMethod), ...] for catalog generation."""
    return [(pascal(case), wire) for case, wire in collect_method_cases(swift_text, enum_name)]


def main() -> int:
    args = build_parser().parse_args()

    swift_text = args.swift.read_text()
    client_request_ts = args.client_request_ts.read_text()
    server_notification_ts = args.server_notification_ts.read_text()
    server_request_ts = args.server_request_ts.read_text()
    schema_definitions = load_schema_definitions(args.schema)

    args.out_dir.mkdir(parents=True, exist_ok=True)
    args.docc_out_dir.mkdir(parents=True, exist_ok=True)

    write_rpc_bridge(
        swift_text,
        client_request_ts,
        schema_definitions,
        args.out_dir / "CodexRPCMethodsGenerated.swift",
    )
    write_server_notifications(
        swift_text,
        server_notification_ts,
        schema_definitions,
        args.out_dir / "CodexServerNotificationsGenerated.swift",
    )
    write_server_requests(
        swift_text,
        server_request_ts,
        schema_definitions,
        args.out_dir / "CodexServerRequestsGenerated.swift",
    )
    write_metadata(args.out_dir / "CodexBindingMetadataGenerated.swift", args.codex_version)

    # Auto-generated DocC catalog articles indexing every method by category.
    write_catalog_article(
        args.docc_out_dir / "RPCMethodsCatalog.md",
        title="RPC Methods Catalog",
        intro=(
            "Every client-to-server RPC method exposed by this Codex binding, grouped by "
            "wire-method prefix. Each entry links to the typed marker enum used with "
            "`CodexClient.call(_:params:)`."
        ),
        namespace="RPC",
        entries=collect_methods_for_catalog(swift_text, "ClientRequestMethod"),
    )
    write_catalog_article(
        args.docc_out_dir / "ServerNotificationsCatalog.md",
        title="Server Notifications Catalog",
        intro=(
            "Every server-to-client notification this Codex binding can decode, grouped by "
            "wire-method prefix. Each entry links to the typed namespace member used with "
            "`CodexClient.notifications(of:)`."
        ),
        namespace="ServerNotifications",
        entries=collect_methods_for_catalog(swift_text, "NotificationMethod"),
    )
    write_catalog_article(
        args.docc_out_dir / "ServerRequestsCatalog.md",
        title="Server Requests Catalog",
        intro=(
            "Every server-to-client request this Codex binding can decode, grouped by "
            "wire-method prefix. Each entry links to the typed namespace member used with "
            "`CodexClient.serverRequests(of:)`."
        ),
        namespace="ServerRequests",
        entries=collect_methods_for_catalog(swift_text, "ServerRequestMethod"),
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
