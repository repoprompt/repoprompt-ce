#!/usr/bin/env python3
"""Focused tests for the bounded Codex app-server schema gate."""

from __future__ import annotations

import contextlib
import copy
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import check_codex_app_server_schema as gate  # noqa: E402


def method_union(method: str, params: dict | None = None) -> dict:
    definitions: dict[str, object] = {}
    properties: dict[str, object] = {
        "method": {"type": "string", "enum": [method]},
    }
    required = ["method"]
    if params is not None:
        definitions["Params"] = params
        properties["params"] = {"$ref": "#/definitions/Params"}
        required.append("params")
    return {
        "oneOf": [
            {
                "type": "object",
                "required": required,
                "properties": properties,
            }
        ],
        "definitions": definitions,
    }


def object_schema(*, required: list[str], properties: dict[str, object]) -> dict:
    return {"type": "object", "required": required, "properties": properties}


def contract(checks: list[dict], *, floor: str = "0.144.6") -> dict:
    return {
        "schemaVersion": 1,
        "minimumCodexVersion": floor,
        "experimental": True,
        "methodChecks": checks,
    }


def response_path(path: str, presence: str, nullable: bool) -> dict:
    return {"path": path, "presence": presence, "nullable": nullable}


class CodexAppServerSchemaGateTests(unittest.TestCase):
    def test_version_parser_accepts_cli_output_and_orders_prereleases(self) -> None:
        self.assertEqual(
            gate.parse_version("codex-cli 0.144.6\n", label="test"),
            gate.SemanticVersion(0, 144, 6),
        )
        self.assertEqual(
            gate.parse_version("0.145.0-rc.2+build.7", label="test"),
            gate.SemanticVersion(0, 145, 0, ("rc", "2")),
        )
        self.assertLess(
            gate.parse_version("0.145.0-rc.2", label="test"),
            gate.parse_version("0.145.0", label="test"),
        )
        self.assertLess(
            gate.parse_version("0.145.0-2", label="test"),
            gate.parse_version("0.145.0-rc", label="test"),
        )
        with self.assertRaisesRegex(gate.GateError, "could not parse"):
            gate.parse_version("Codex unknown", label="test")

    def test_bundle_validation_accepts_declared_fields_nested_paths_and_enum(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            union = method_union(
                "thread/example",
                object_schema(
                    required=["threadId"],
                    properties={
                        "threadId": {"type": "string"},
                        "mode": {"type": "string", "enum": ["enabled", "disabled"]},
                    },
                ),
            )
            response = object_schema(
                required=["thread"],
                properties={
                    "thread": {
                        "type": "object",
                        "required": ["id"],
                        "properties": {"id": {"type": "string"}},
                    }
                },
            )
            (root / "ClientRequest.json").write_text(json.dumps(union), encoding="utf-8")
            (root / "Response.json").write_text(json.dumps(response), encoding="utf-8")
            fixture = contract([
                {
                    "union": "ClientRequest.json",
                    "method": "thread/example",
                    "alwaysSent": ["threadId", "mode"],
                    "enumValues": {"mode": ["disabled"]},
                    "responseSchema": "Response.json",
                    "consumedResponse": [
                        response_path("thread.id", "required", False),
                    ],
                }
            ])

            errors, counts = gate.validate_bundle(root, fixture)

            self.assertEqual(errors, [])
            self.assertEqual(counts, {"methods": 1, "parameterPaths": 2, "responsePaths": 1})

    def test_response_presence_nullability_and_conditional_drift_are_explicit(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "ClientRequest.json").write_text(
                json.dumps(method_union("thread/goal/get")), encoding="utf-8"
            )
            response = {
                "type": "object",
                "properties": {
                    "goal": {
                        "anyOf": [
                            {"$ref": "#/definitions/Goal"},
                            {"type": "null"},
                        ]
                    }
                },
                "definitions": {
                    "Goal": object_schema(
                        required=["id", "status"],
                        properties={
                            "id": {"type": "string"},
                            "status": {"type": "string"},
                        },
                    )
                },
            }
            response_path_file = root / "Response.json"
            response_path_file.write_text(json.dumps(response), encoding="utf-8")
            fixture = contract([
                {
                    "union": "ClientRequest.json",
                    "method": "thread/goal/get",
                    "responseSchema": "Response.json",
                    "consumedResponse": [
                        response_path("goal", "optional", True),
                        response_path("goal.id", "conditional", False),
                        response_path("goal.status", "conditional", False),
                    ],
                }
            ])
            self.assertEqual(gate.validate_bundle(root, fixture)[0], [])

            optional_status = copy.deepcopy(response)
            optional_status["definitions"]["Goal"]["required"].remove("status")
            response_path_file.write_text(json.dumps(optional_status), encoding="utf-8")
            errors, _ = gate.validate_bundle(root, fixture)
            self.assertTrue(any("presence changed from 'conditional' to 'optional'" in e for e in errors))

            nonnullable_goal = copy.deepcopy(response)
            nonnullable_goal["properties"]["goal"] = {"$ref": "#/definitions/Goal"}
            response_path_file.write_text(json.dumps(nonnullable_goal), encoding="utf-8")
            errors, _ = gate.validate_bundle(root, fixture)
            self.assertTrue(any("nullability changed from True to False" in e for e in errors))

    def test_response_enum_only_check_loads_response_schema(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "ClientRequest.json").write_text(
                json.dumps(method_union("thread/example")), encoding="utf-8"
            )
            response = object_schema(
                required=["status"],
                properties={
                    "status": {"type": "string", "enum": ["ready"]},
                },
            )
            (root / "Response.json").write_text(json.dumps(response), encoding="utf-8")
            fixture = contract([
                {
                    "union": "ClientRequest.json",
                    "method": "thread/example",
                    "responseSchema": "Response.json",
                    "responseEnumValues": {"status": ["blocked"]},
                }
            ])

            errors, _ = gate.validate_bundle(root, fixture)

            self.assertTrue(any("sends response enum value 'blocked'" in e for e in errors))

    def test_nested_required_response_field_is_detected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "ClientRequest.json").write_text(
                json.dumps(method_union("thread/example")), encoding="utf-8"
            )
            response = object_schema(
                required=["result"],
                properties={
                    "result": object_schema(
                        required=["existing", "newRequired"],
                        properties={
                            "existing": {"type": "string"},
                            "newRequired": {"type": "string"},
                        },
                    )
                },
            )
            (root / "Response.json").write_text(json.dumps(response), encoding="utf-8")
            fixture = contract([
                {
                    "union": "ClientRequest.json",
                    "method": "thread/example",
                    "responseSchema": "Response.json",
                    "alwaysSentResponse": ["result", "result.existing"],
                }
            ])

            errors, _ = gate.validate_bundle(root, fixture)

            self.assertTrue(
                any("requires response field 'result.newRequired'" in e for e in errors)
            )

    def test_discriminated_nested_sent_and_consumed_shapes_are_mutation_checked(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            params = object_schema(
                required=["eventId"],
                properties={
                    "eventId": {"type": "string"},
                    "input": {
                        "type": "array",
                        "items": {
                            "oneOf": [
                                object_schema(
                                    required=["type", "text", "text_elements"],
                                    properties={
                                        "type": {"const": "text"},
                                        "text": {"type": "string"},
                                        "text_elements": {"type": "array", "items": True},
                                    },
                                ),
                                object_schema(
                                    required=["type", "url"],
                                    properties={
                                        "type": {"const": "image"},
                                        "url": {"type": "string"},
                                    },
                                ),
                            ]
                        },
                    },
                    "item": {
                        "oneOf": [
                            object_schema(
                                required=["type", "id", "command"],
                                properties={
                                    "type": {"const": "commandExecution"},
                                    "id": {"type": "string"},
                                    "command": {"type": "string"},
                                },
                            )
                        ]
                    },
                },
            )
            schema_path = root / "ClientRequest.json"
            schema_path.write_text(
                json.dumps(method_union("turn/example", params)), encoding="utf-8"
            )
            fixture = contract([
                {
                    "union": "ClientRequest.json",
                    "method": "turn/example",
                    "consumedParams": [
                        response_path("eventId", "required", False),
                    ],
                    "sentParamVariants": [
                        {
                            "path": "input[]",
                            "discriminator": "type",
                            "value": "text",
                            "alwaysSent": ["type", "text", "text_elements"],
                        }
                    ],
                    "consumedParamVariants": [
                        {
                            "path": "item",
                            "discriminator": "type",
                            "value": "commandExecution",
                            "consumed": [
                                response_path("type", "required", False),
                                response_path("id", "required", False),
                                response_path("command", "required", False),
                            ],
                        }
                    ],
                }
            ])
            self.assertEqual(gate.validate_bundle(root, fixture)[0], [])

            mutated = copy.deepcopy(params)
            del mutated["properties"]["input"]["items"]["oneOf"][0]["properties"]["text_elements"]
            mutated["required"].remove("eventId")
            mutated["properties"]["eventId"]["type"] = ["string", "null"]
            command_variant = mutated["properties"]["item"]["oneOf"][0]
            command_variant["required"].remove("id")
            command_variant["properties"]["id"]["type"] = ["string", "null"]
            del command_variant["properties"]["command"]
            schema_path.write_text(
                json.dumps(method_union("turn/example", mutated)), encoding="utf-8"
            )
            rendered = "\n".join(gate.validate_bundle(root, fixture)[0])
            self.assertIn("sends field 'text_elements'", rendered)
            self.assertIn("params: consumed path 'eventId' presence changed", rendered)
            self.assertIn("params: consumed path 'eventId' nullability changed", rendered)
            self.assertIn("consumed path 'id' presence changed", rendered)
            self.assertIn("consumed path 'id' nullability changed", rendered)
            self.assertIn("consumed path 'command' is no longer declared", rendered)

    def test_method_discovery_accepts_ref_allof_and_const_refactors(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            union = {
                "allOf": [{"$ref": "#/definitions/MethodUnion"}],
                "definitions": {
                    "MethodUnion": {
                        "oneOf": [
                            {
                                "allOf": [
                                    {"$ref": "#/definitions/Envelope"},
                                    {
                                        "type": "object",
                                        "properties": {
                                            "method": {"const": "thread/refactored"},
                                            "params": {"$ref": "#/definitions/Params"},
                                        },
                                    },
                                ]
                            }
                        ]
                    },
                    "Envelope": {
                        "type": "object",
                        "required": ["method", "params"],
                    },
                    "Params": object_schema(
                        required=["threadId"],
                        properties={"threadId": {"type": "string"}},
                    ),
                },
            }
            (root / "ClientRequest.json").write_text(json.dumps(union), encoding="utf-8")
            fixture = contract([
                {
                    "union": "ClientRequest.json",
                    "method": "thread/refactored",
                    "alwaysSent": ["threadId"],
                }
            ])
            self.assertEqual(gate.validate_bundle(root, fixture)[0], [])

    def test_literal_composition_intersects_allof_and_selects_discriminator_branch(self) -> None:
        document = {
            "definitions": {
                "InputKind": {"type": "string", "enum": ["text", "image"]},
            }
        }
        text_literal = {
            "allOf": [
                {"$ref": "#/definitions/InputKind"},
                {"const": "text"},
            ]
        }
        impossible_literal = {
            "allOf": [
                {"enum": ["text"]},
                {"const": "image"},
            ]
        }
        union_literal = {
            "oneOf": [
                {"const": "text"},
                {"enum": ["image"]},
            ]
        }

        self.assertEqual(gate.literal_values(document, text_literal), {"text"})
        self.assertEqual(gate.literal_values(document, impossible_literal), set())
        self.assertEqual(gate.literal_values(document, union_literal), {"text", "image"})

        input_schema = {
            "oneOf": [
                object_schema(
                    required=["type", "text"],
                    properties={
                        "type": text_literal,
                        "text": {"type": "string"},
                    },
                ),
                object_schema(
                    required=["type", "url"],
                    properties={
                        "type": {
                            "allOf": [
                                {"$ref": "#/definitions/InputKind"},
                                {"const": "image"},
                            ]
                        },
                        "url": {"type": "string"},
                    },
                ),
            ]
        }
        selected = gate.discriminated_variant(
            document,
            input_schema,
            discriminator="type",
            value="image",
        )
        self.assertIsNotNone(selected)
        self.assertTrue(gate.nodes_at_path(document, selected, "url"))
        self.assertFalse(gate.nodes_at_path(document, selected, "text"))

    def test_incoming_enum_contract_is_exhaustive(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "ClientRequest.json").write_text(
                json.dumps(method_union("thread/goal/get")), encoding="utf-8"
            )
            response = object_schema(
                required=["goal"],
                properties={
                    "goal": object_schema(
                        required=["status"],
                        properties={
                            "status": {"type": "string", "enum": ["active", "paused"]}
                        },
                    )
                },
            )
            response_file = root / "Response.json"
            response_file.write_text(json.dumps(response), encoding="utf-8")
            fixture = contract([
                {
                    "union": "ClientRequest.json",
                    "method": "thread/goal/get",
                    "responseSchema": "Response.json",
                    "consumedResponse": [
                        response_path("goal.status", "required", False),
                    ],
                    "consumedEnumValues": {"goal.status": ["active", "paused"]},
                }
            ])
            self.assertEqual(gate.validate_bundle(root, fixture)[0], [])

            response["properties"]["goal"]["properties"]["status"]["enum"].append("blocked")
            response_file.write_text(json.dumps(response), encoding="utf-8")
            errors, _ = gate.validate_bundle(root, fixture)
            self.assertTrue(any("incoming enum 'goal.status' changed" in error for error in errors))

    def test_bundle_validation_reports_removed_method_and_new_required_param(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            union = method_union(
                "thread/present",
                object_schema(
                    required=["threadId", "newRequired"],
                    properties={
                        "threadId": {"type": "string"},
                        "newRequired": {"type": "string"},
                    },
                ),
            )
            (root / "ClientRequest.json").write_text(json.dumps(union), encoding="utf-8")
            fixture = contract([
                {
                    "union": "ClientRequest.json",
                    "method": "thread/present",
                    "alwaysSent": ["threadId"],
                },
                {
                    "union": "ClientRequest.json",
                    "method": "thread/removed",
                },
            ])

            errors, _counts = gate.validate_bundle(root, fixture)

            self.assertTrue(any("schema now requires param 'newRequired'" in error for error in errors))
            self.assertTrue(any("thread/removed: method is no longer declared" in error for error in errors))

    def test_contract_validation_is_fail_closed(self) -> None:
        base = contract([
            {
                "union": "ClientRequest.json",
                "method": "initialize",
            }
        ])
        gate.validate_contract(base)

        mutations = [
            ("schemaVersion", {**base, "schemaVersion": 2}),
            ("invalid version", {**base, "minimumCodexVersion": "latest"}),
            ("unknown top-level", {**base, "minimumCodexVerison": "0.1.0"}),
            (
                "unknown method key",
                {
                    **base,
                    "methodChecks": [
                        {
                            **base["methodChecks"][0],
                            "consumedReponse": [],
                        }
                    ],
                },
            ),
            (
                "unknown response key",
                {
                    **base,
                    "methodChecks": [
                        {
                            **base["methodChecks"][0],
                            "responseSchema": "Response.json",
                            "consumedResponse": [
                                {
                                    **response_path("value", "required", False),
                                    "optionl": True,
                                }
                            ],
                        }
                    ],
                },
            ),
        ]
        for label, mutation in mutations:
            with self.subTest(label=label), self.assertRaises(gate.GateError):
                gate.validate_contract(mutation)

    def test_main_invokes_codex_with_experimental_and_enforces_stable_floor(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            marker = root / "args.json"
            fake_codex = root / "fake-codex"
            script_template = """#!/usr/bin/env python3
import json
import pathlib
import sys

marker = pathlib.Path(%s)
if sys.argv[1:] == ["--version"]:
    print(%s)
    raise SystemExit(0)
marker.write_text(json.dumps(sys.argv[1:]), encoding="utf-8")
out = pathlib.Path(sys.argv[sys.argv.index("--out") + 1])
out.mkdir(parents=True, exist_ok=True)
(out / "ClientNotification.json").write_text(json.dumps({
    "oneOf": [{
        "type": "object",
        "required": ["method"],
        "properties": {"method": {"const": "initialized"}}
    }]
}), encoding="utf-8")
"""
            fake_codex.write_text(
                script_template % (repr(str(marker)), repr("codex-cli 0.144.6")),
                encoding="utf-8",
            )
            fake_codex.chmod(0o755)
            contract_path = root / "contract.json"
            contract_path.write_text(
                json.dumps(
                    contract([
                        {"union": "ClientNotification.json", "method": "initialized"}
                    ])
                ),
                encoding="utf-8",
            )

            stdout = io.StringIO()
            stderr = io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                result = gate.main(
                    ["--codex", str(fake_codex), "--contract", str(contract_path)]
                )

            self.assertEqual(result, 0, stderr.getvalue())
            self.assertIn("Codex CLI: 0.144.6", stdout.getvalue())
            generated_args = json.loads(marker.read_text(encoding="utf-8"))
            self.assertEqual(
                generated_args[:3],
                ["app-server", "generate-json-schema", "--experimental"],
            )
            self.assertIn("--out", generated_args)

            fake_codex.write_text(
                script_template % (repr(str(marker)), repr("codex-cli 0.145.0-rc.1")),
                encoding="utf-8",
            )
            fake_codex.chmod(0o755)
            contract_path.write_text(
                json.dumps(
                    contract(
                        [{"union": "ClientNotification.json", "method": "initialized"}],
                        floor="0.145.0",
                    )
                ),
                encoding="utf-8",
            )
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                result = gate.main(
                    ["--codex", str(fake_codex), "--contract", str(contract_path)]
                )
            self.assertEqual(result, 1)
            self.assertIn(
                "installed Codex CLI 0.145.0-rc.1 is below the contract floor 0.145.0",
                stderr.getvalue(),
            )


if __name__ == "__main__":
    unittest.main()
