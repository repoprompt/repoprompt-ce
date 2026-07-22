#!/usr/bin/env python3
"""Validate RepoPrompt CE's bounded Codex app-server contract against generated schemas."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from functools import total_ordering
from itertools import product
from pathlib import Path
from typing import Any, Mapping, Sequence

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_CONTRACT = SCRIPT_DIR / "Fixtures" / "codex-app-server-contract.json"
VERSION_PATTERN = re.compile(
    r"codex-cli\s+(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?"
)
PLAIN_VERSION_PATTERN = re.compile(
    r"\s*(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?\s*"
)
PRESENCE_VALUES = {"required", "optional", "conditional"}
TOP_LEVEL_KEYS = {"schemaVersion", "minimumCodexVersion", "experimental", "methodChecks"}
METHOD_CHECK_KEYS = {
    "union",
    "method",
    "alwaysSent",
    "maySend",
    "consumedParams",
    "enumValues",
    "sentParamVariants",
    "consumedParamVariants",
    "responseSchema",
    "consumedResponse",
    "alwaysSentResponse",
    "maySendResponse",
    "responseEnumValues",
    "consumedEnumValues",
}
VARIANT_KEYS = {"path", "discriminator", "value", "alwaysSent", "maySend", "consumed"}
RESPONSE_PATH_KEYS = {"path", "presence", "nullable"}


class GateError(RuntimeError):
    """Actionable schema-gate failure."""


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise GateError(f"required JSON file is missing: {path}") from exc
    except json.JSONDecodeError as exc:
        raise GateError(f"invalid JSON in {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise GateError(f"expected a JSON object in {path}")
    return value


@total_ordering
@dataclass(frozen=True)
class SemanticVersion:
    major: int
    minor: int
    patch: int
    prerelease: tuple[str, ...] = ()

    def __str__(self) -> str:
        base = f"{self.major}.{self.minor}.{self.patch}"
        return base + "-" + ".".join(self.prerelease) if self.prerelease else base

    def __lt__(self, other: object) -> bool:
        if not isinstance(other, SemanticVersion):
            return NotImplemented
        core = (self.major, self.minor, self.patch)
        other_core = (other.major, other.minor, other.patch)
        if core != other_core:
            return core < other_core
        if not self.prerelease:
            return False
        if not other.prerelease:
            return True
        for left, right in zip(self.prerelease, other.prerelease):
            if left == right:
                continue
            left_numeric = left.isdigit()
            right_numeric = right.isdigit()
            if left_numeric and right_numeric:
                return int(left) < int(right)
            if left_numeric != right_numeric:
                return left_numeric
            return left < right
        return len(self.prerelease) < len(other.prerelease)


def parse_version(value: str, *, label: str) -> SemanticVersion:
    match = VERSION_PATTERN.search(value) or PLAIN_VERSION_PATTERN.fullmatch(value)
    if not match:
        raise GateError(f"could not parse {label} version from {value!r}")
    major, minor, patch, prerelease = match.groups()
    return SemanticVersion(
        int(major),
        int(minor),
        int(patch),
        tuple(prerelease.split(".")) if prerelease else (),
    )


def format_version(version: SemanticVersion) -> str:
    return str(version)


def run_command(argv: Sequence[str]) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(argv, check=False, capture_output=True, text=True)
    except FileNotFoundError as exc:
        raise GateError(
            f"Codex CLI was not found at {argv[0]!r}. Install the pinned CI version "
            "or pass --codex /path/to/codex."
        ) from exc


def installed_codex_version(codex: str) -> tuple[SemanticVersion, str]:
    result = run_command([codex, "--version"])
    output = "\n".join(part.strip() for part in (result.stdout, result.stderr) if part.strip())
    if result.returncode != 0:
        raise GateError(
            f"{codex} --version failed with exit code {result.returncode}:\n{output or '<no output>'}"
        )
    return parse_version(output, label="installed Codex CLI"), output


def generate_schema_bundle(codex: str, output_dir: Path, *, experimental: bool) -> None:
    argv = [codex, "app-server", "generate-json-schema"]
    if experimental:
        argv.append("--experimental")
    argv.extend(["--out", str(output_dir)])
    result = run_command(argv)
    if result.returncode == 0:
        return
    details = "\n".join(part.strip() for part in (result.stdout, result.stderr) if part.strip())
    raise GateError(
        "Codex app-server schema generation failed "
        f"(exit {result.returncode}): {' '.join(argv)}\n{details or '<no output>'}"
    )


def dereference(document: Mapping[str, Any], node: Any) -> Any:
    seen: set[str] = set()
    while isinstance(node, dict) and isinstance(node.get("$ref"), str):
        reference = node["$ref"]
        if not reference.startswith("#/definitions/"):
            return node
        if reference in seen:
            raise GateError(f"cyclic local schema reference: {reference}")
        seen.add(reference)
        name = reference.removeprefix("#/definitions/")
        definitions = document.get("definitions")
        if not isinstance(definitions, dict) or name not in definitions:
            raise GateError(f"unresolved local schema reference: {reference}")
        node = definitions[name]
    return node


def constraint_variants(
    document: Mapping[str, Any], node: Any
) -> list[list[Mapping[str, Any]]]:
    node = dereference(document, node)
    if node is True:
        return [[{}]]
    if node is False or not isinstance(node, dict):
        return []

    base = {key: value for key, value in node.items() if key not in {"allOf", "anyOf", "oneOf", "$ref"}}
    variants: list[list[Mapping[str, Any]]] = [[base]]
    all_of = node.get("allOf")
    if isinstance(all_of, list):
        for child in all_of:
            child_variants = constraint_variants(document, child)
            variants = [left + right for left, right in product(variants, child_variants)]

    alternatives: list[list[Mapping[str, Any]]] | None = None
    for keyword in ("anyOf", "oneOf"):
        raw_alternatives = node.get(keyword)
        if isinstance(raw_alternatives, list):
            expanded = [
                constraints
                for alternative in raw_alternatives
                for constraints in constraint_variants(document, alternative)
            ]
            alternatives = expanded if alternatives is None else [
                left + right for left, right in product(alternatives, expanded)
            ]
    if alternatives is not None:
        variants = [left + right for left, right in product(variants, alternatives)]
    return variants


def combined_schema(schemas: Sequence[Any]) -> Any:
    if len(schemas) == 1:
        return schemas[0]
    return {"allOf": list(schemas)}


@dataclass(frozen=True)
class PropertyOption:
    exists: bool
    required: bool
    schema: Any = None


def property_options(
    document: Mapping[str, Any], node: Any, name: str
) -> list[PropertyOption]:
    options: list[PropertyOption] = []
    for constraints in constraint_variants(document, node):
        schemas: list[Any] = []
        required = False
        for constraint in constraints:
            properties = constraint.get("properties")
            if isinstance(properties, dict) and name in properties:
                schemas.append(properties[name])
            required_names = constraint.get("required")
            if isinstance(required_names, list) and name in required_names:
                required = True
        options.append(
            PropertyOption(bool(schemas), required, combined_schema(schemas) if schemas else None)
        )
    return options


def item_options(document: Mapping[str, Any], node: Any) -> list[Any | None]:
    options: list[Any | None] = []
    for constraints in constraint_variants(document, node):
        schemas = [constraint["items"] for constraint in constraints if "items" in constraint]
        options.append(combined_schema(schemas) if schemas else None)
    return options


def direct_constraint_allows_null(constraint: Mapping[str, Any]) -> bool:
    if "const" in constraint:
        return constraint["const"] is None
    enum_values = constraint.get("enum")
    if isinstance(enum_values, list):
        return None in enum_values
    type_value = constraint.get("type")
    if isinstance(type_value, str):
        return type_value == "null"
    if isinstance(type_value, list):
        return "null" in type_value
    return True


def schema_allows_null(document: Mapping[str, Any], node: Any) -> bool:
    if node is True:
        return True
    if node is False:
        return False
    variants = constraint_variants(document, node)
    return any(all(direct_constraint_allows_null(part) for part in variant) for variant in variants)


def literal_values(document: Mapping[str, Any], node: Any) -> set[Any]:
    values: set[Any] = set()
    for constraints in constraint_variants(document, node):
        literal_constraints: list[set[Any]] = []
        for constraint in constraints:
            constraint_values: set[Any] | None = None
            if "const" in constraint:
                constraint_values = {constraint["const"]}
            enum_values = constraint.get("enum")
            if isinstance(enum_values, list):
                enum_set = set(enum_values)
                constraint_values = (
                    enum_set
                    if constraint_values is None
                    else constraint_values.intersection(enum_set)
                )
            if constraint_values is not None:
                literal_constraints.append(constraint_values)
        if literal_constraints:
            values.update(set.intersection(*literal_constraints))
    return values


def nodes_at_path(document: Mapping[str, Any], node: Any, path: str) -> list[Any]:
    candidates: list[Any] = [node]
    if not path:
        return candidates
    for raw_segment in path.split("."):
        is_array = raw_segment.endswith("[]")
        segment = raw_segment[:-2] if is_array else raw_segment
        next_candidates: list[Any] = []
        for candidate in candidates:
            for option in property_options(document, candidate, segment):
                if not option.exists:
                    continue
                if is_array:
                    next_candidates.extend(
                        item for item in item_options(document, option.schema) if item is not None
                    )
                else:
                    next_candidates.append(option.schema)
        candidates = next_candidates
        if not candidates:
            break
    return candidates


@dataclass(frozen=True)
class PathAnalysis:
    declared: bool
    presence: str | None
    nullable: bool


def analyze_path(document: Mapping[str, Any], node: Any, path: str) -> PathAnalysis:
    states: list[tuple[Any, bool]] = [(node, False)]
    terminal: list[tuple[bool, bool, bool]] = []
    segments = path.split(".")
    for index, raw_segment in enumerate(segments):
        is_array = raw_segment.endswith("[]")
        segment = raw_segment[:-2] if is_array else raw_segment
        next_states: list[tuple[Any, bool]] = []
        for candidate, ancestor_conditional in states:
            options = property_options(document, candidate, segment)
            alternative_missing = any(not option.exists for option in options)
            for option in options:
                if not option.exists:
                    continue
                nullable = schema_allows_null(document, option.schema)
                conditional = (
                    ancestor_conditional or alternative_missing or not option.required or nullable
                )
                if is_array:
                    items = item_options(document, option.schema)
                    item_missing = any(item is None for item in items)
                    for item in items:
                        if item is not None:
                            next_states.append((item, conditional or item_missing))
                elif index == len(segments) - 1:
                    terminal.append((option.required, ancestor_conditional or alternative_missing, nullable))
                else:
                    next_states.append((option.schema, conditional))
        if index != len(segments) - 1:
            states = next_states
            if not states:
                break

    if not terminal:
        return PathAnalysis(False, None, False)
    if any(not required for required, _conditional, _nullable in terminal):
        presence = "optional"
    elif any(conditional for _required, conditional, _nullable in terminal):
        presence = "conditional"
    else:
        presence = "required"
    return PathAnalysis(True, presence, any(nullable for _required, _conditional, nullable in terminal))


def enum_values_at_path(document: Mapping[str, Any], node: Any, path: str) -> set[Any]:
    values: set[Any] = set()
    for candidate in nodes_at_path(document, node, path):
        values.update(literal_values(document, candidate))
    return values


def method_branches(document: Mapping[str, Any], filename: str) -> dict[str, Mapping[str, Any]]:
    branches: dict[str, Mapping[str, Any]] = {}
    for constraints in constraint_variants(document, document):
        branch: Mapping[str, Any] = {"allOf": constraints}
        methods = enum_values_at_path(document, branch, "method")
        if len(methods) != 1:
            continue
        method = next(iter(methods))
        if not isinstance(method, str):
            continue
        if method in branches:
            raise GateError(f"{filename} declares duplicate method branch {method!r}")
        branches[method] = branch
    if not branches:
        raise GateError(f"{filename} does not contain a discoverable method union")
    return branches


def param_schema(document: Mapping[str, Any], branch: Mapping[str, Any]) -> Mapping[str, Any] | None:
    schemas = nodes_at_path(document, branch, "params")
    if not schemas:
        return None
    schema = {"anyOf": schemas} if len(schemas) > 1 else schemas[0]
    resolved = dereference(document, schema)
    return resolved if isinstance(resolved, dict) else None


def string_list(value: Any, *, label: str) -> list[str]:
    if value is None:
        return []
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise GateError(f"{label} must be an array of strings")
    return list(value)


def reject_unknown_keys(value: Mapping[str, Any], allowed: set[str], *, label: str) -> None:
    unknown = sorted(set(value) - allowed)
    if unknown:
        raise GateError(f"{label} contains unknown keys: {', '.join(unknown)}")


def validate_enum_map(value: Any, *, label: str) -> None:
    if value is None:
        return
    if not isinstance(value, dict):
        raise GateError(f"{label} must be an object")
    for path, values in value.items():
        if not isinstance(path, str):
            raise GateError(f"{label} keys must be strings")
        string_list(values, label=f"{label}.{path}")


def validate_variant_entries(value: Any, *, label: str, direction: str) -> None:
    if value is None:
        return
    if not isinstance(value, list):
        raise GateError(f"{label} must be an array")
    for index, entry in enumerate(value):
        entry_label = f"{label}[{index}]"
        if not isinstance(entry, dict):
            raise GateError(f"{entry_label} must be an object")
        reject_unknown_keys(entry, VARIANT_KEYS, label=entry_label)
        for key in ("path", "discriminator", "value"):
            if not isinstance(entry.get(key), str) or not entry[key]:
                raise GateError(f"{entry_label}.{key} must be a non-empty string")
        if direction == "sent":
            if "alwaysSent" not in entry:
                raise GateError(f"{entry_label} requires alwaysSent")
            string_list(entry.get("alwaysSent"), label=f"{entry_label}.alwaysSent")
            string_list(entry.get("maySend"), label=f"{entry_label}.maySend")
            if "consumed" in entry:
                raise GateError(f"{entry_label}.consumed is not valid for a sent variant")
        else:
            if "consumed" not in entry:
                raise GateError(f"{entry_label} requires consumed")
            validate_consumed_paths(entry.get("consumed"), label=f"{entry_label}.consumed")
            if "alwaysSent" in entry or "maySend" in entry:
                raise GateError(f"{entry_label} cannot declare sent fields")


def validate_consumed_paths(value: Any, *, label: str) -> None:
    if value is None:
        return
    if not isinstance(value, list):
        raise GateError(f"{label} must be an array")
    for index, entry in enumerate(value):
        entry_label = f"{label}[{index}]"
        if not isinstance(entry, dict):
            raise GateError(f"{entry_label} must be an object")
        reject_unknown_keys(entry, RESPONSE_PATH_KEYS, label=entry_label)
        if set(entry) != RESPONSE_PATH_KEYS:
            missing = sorted(RESPONSE_PATH_KEYS - set(entry))
            raise GateError(f"{entry_label} is missing keys: {', '.join(missing)}")
        if not isinstance(entry["path"], str) or not entry["path"]:
            raise GateError(f"{entry_label}.path must be a non-empty string")
        if entry["presence"] not in PRESENCE_VALUES:
            raise GateError(
                f"{entry_label}.presence must be one of {sorted(PRESENCE_VALUES)!r}"
            )
        if not isinstance(entry["nullable"], bool):
            raise GateError(f"{entry_label}.nullable must be a boolean")


def validate_contract(contract: Mapping[str, Any]) -> None:
    reject_unknown_keys(contract, TOP_LEVEL_KEYS, label="contract")
    missing_top = sorted(TOP_LEVEL_KEYS - set(contract))
    if missing_top:
        raise GateError(f"contract is missing required keys: {', '.join(missing_top)}")
    if type(contract["schemaVersion"]) is not int or contract["schemaVersion"] != 1:
        raise GateError("contract schemaVersion must be the integer 1")
    if not isinstance(contract["minimumCodexVersion"], str):
        raise GateError("contract minimumCodexVersion must be a string")
    parse_version(contract["minimumCodexVersion"], label="minimum Codex CLI")
    if not isinstance(contract["experimental"], bool):
        raise GateError("contract experimental must be a boolean")
    checks = contract["methodChecks"]
    if not isinstance(checks, list):
        raise GateError("contract methodChecks must be an array")
    if not checks:
        raise GateError("contract methodChecks must not be empty")

    identities: set[tuple[str, str]] = set()
    for index, check in enumerate(checks):
        label = f"contract.methodChecks[{index}]"
        if not isinstance(check, dict):
            raise GateError(f"{label} must be an object")
        reject_unknown_keys(check, METHOD_CHECK_KEYS, label=label)
        for key in ("union", "method"):
            if not isinstance(check.get(key), str) or not check[key]:
                raise GateError(f"{label}.{key} must be a non-empty string")
        identity = (check["union"], check["method"])
        if identity in identities:
            raise GateError(f"{label} duplicates {identity[0]} {identity[1]}")
        identities.add(identity)

        for key in (
            "alwaysSent",
            "maySend",
            "alwaysSentResponse",
            "maySendResponse",
        ):
            if key in check:
                string_list(check[key], label=f"{label}.{key}")
        for key in (
            "enumValues",
            "responseEnumValues",
            "consumedEnumValues",
        ):
            validate_enum_map(check.get(key), label=f"{label}.{key}")
        validate_variant_entries(
            check.get("sentParamVariants"), label=f"{label}.sentParamVariants", direction="sent"
        )
        validate_variant_entries(
            check.get("consumedParamVariants"),
            label=f"{label}.consumedParamVariants",
            direction="consumed",
        )
        validate_consumed_paths(check.get("consumedParams"), label=f"{label}.consumedParams")
        validate_consumed_paths(
            check.get("consumedResponse"), label=f"{label}.consumedResponse"
        )

        if "responseSchema" in check and (
            not isinstance(check["responseSchema"], str) or not check["responseSchema"]
        ):
            raise GateError(f"{label}.responseSchema must be a non-empty string")
        response_keys = {
            "consumedResponse",
            "alwaysSentResponse",
            "maySendResponse",
            "responseEnumValues",
            "consumedEnumValues",
        }
        if any(key in check for key in response_keys):
            if not isinstance(check.get("responseSchema"), str) or not check["responseSchema"]:
                raise GateError(f"{label} declares response checks but has no responseSchema")


def required_property_names(document: Mapping[str, Any], node: Any) -> set[str]:
    variants = constraint_variants(document, node)
    if not variants:
        return set()
    required_sets: list[set[str]] = []
    for constraints in variants:
        names: set[str] = set()
        for constraint in constraints:
            required = constraint.get("required")
            if isinstance(required, list):
                names.update(name for name in required if isinstance(name, str))
        required_sets.append(names)
    return set.intersection(*required_sets) if required_sets else set()


def missing_required_sent_paths(
    document: Mapping[str, Any],
    node: Any,
    *,
    always_sent: Sequence[str],
    may_send: Sequence[str],
) -> list[str]:
    always = set(always_sent)
    declared = list(always_sent) + list(may_send)
    missing = sorted(required_property_names(document, node) - always)
    for parent_path in declared:
        for child_node in nodes_at_path(document, node, parent_path):
            for child in required_property_names(document, child_node):
                child_path = f"{parent_path}.{child}"
                if child_path not in always:
                    missing.append(child_path)
    return sorted(set(missing))


def discriminated_variant(
    document: Mapping[str, Any],
    node: Any,
    *,
    discriminator: str,
    value: str,
) -> Mapping[str, Any] | None:
    matches: list[Mapping[str, Any]] = []
    for constraints in constraint_variants(document, node):
        candidate: Mapping[str, Any] = {"allOf": constraints}
        if value in enum_values_at_path(document, candidate, discriminator):
            matches.append(candidate)
    if not matches:
        return None
    return matches[0] if len(matches) == 1 else {"anyOf": matches}


def consumed_path_errors(
    document: Mapping[str, Any],
    node: Any,
    entries: Sequence[Mapping[str, Any]],
    *,
    label: str,
) -> list[str]:
    errors: list[str] = []
    for entry in entries:
        path = entry["path"]
        analysis = analyze_path(document, node, path)
        if not analysis.declared:
            errors.append(f"{label}: consumed path {path!r} is no longer declared")
            continue
        if analysis.presence != entry["presence"]:
            errors.append(
                f"{label}: consumed path {path!r} presence changed from "
                f"{entry['presence']!r} to {analysis.presence!r}"
            )
        if analysis.nullable != entry["nullable"]:
            errors.append(
                f"{label}: consumed path {path!r} nullability changed from "
                f"{entry['nullable']!r} to {analysis.nullable!r}"
            )
    return errors


def validate_param_variants(
    document: Mapping[str, Any],
    params: Mapping[str, Any],
    entries: Any,
    *,
    label: str,
    direction: str,
) -> tuple[list[str], int]:
    errors: list[str] = []
    count = 0
    for entry in entries or []:
        path = entry["path"]
        discriminator = entry["discriminator"]
        value = entry["value"]
        roots = nodes_at_path(document, params, path)
        variant = next(
            (
                selected
                for root in roots
                if (
                    selected := discriminated_variant(
                        document, root, discriminator=discriminator, value=value
                    )
                )
                is not None
            ),
            None,
        )
        variant_label = f"{label} {path} {discriminator}={value!r}"
        if variant is None:
            errors.append(f"{variant_label}: discriminated variant is no longer declared")
            continue
        if direction == "sent":
            fields = string_list(
                entry.get("alwaysSent"), label=f"{variant_label}.alwaysSent"
            ) + string_list(entry.get("maySend"), label=f"{variant_label}.maySend")
            count += len(fields)
            for field in fields:
                if not nodes_at_path(document, variant, field):
                    errors.append(
                        f"{variant_label}: RPCE sends field {field!r}, "
                        "but the schema does not declare it"
                    )
            always = string_list(entry.get("alwaysSent"), label=f"{variant_label}.alwaysSent")
            missing_required = sorted(required_property_names(document, variant) - set(always))
            for field in missing_required:
                errors.append(
                    f"{variant_label}: schema now requires field {field!r}, "
                    "but RPCE does not declare it as always sent"
                )
        else:
            consumed = list(entry.get("consumed") or [])
            count += len(consumed)
            errors.extend(
                consumed_path_errors(
                    document,
                    variant,
                    consumed,
                    label=variant_label,
                )
            )
    return errors, count


def validate_method_check(
    schema_dir: Path,
    documents: dict[str, dict[str, Any]],
    branch_indexes: dict[str, dict[str, Mapping[str, Any]]],
    check: Mapping[str, Any],
) -> tuple[list[str], int, int]:
    union = check["union"]
    method = check["method"]
    errors: list[str] = []
    if union not in documents:
        document_path = schema_dir / union
        documents[union] = load_json(document_path)
        branch_indexes[union] = method_branches(documents[union], union)
    document = documents[union]
    branch = branch_indexes[union].get(method)
    label = f"{union} {method}"
    if branch is None:
        return [f"{label}: method is no longer declared"], 0, 0

    params = param_schema(document, branch)
    always_sent = string_list(check.get("alwaysSent"), label=f"{label}.alwaysSent")
    may_send = string_list(check.get("maySend"), label=f"{label}.maySend")
    consumed_params = list(check.get("consumedParams") or [])
    consumed_param_paths = [entry["path"] for entry in consumed_params]
    declared_params = always_sent + may_send + consumed_param_paths
    variant_entries = list(check.get("sentParamVariants") or []) + list(
        check.get("consumedParamVariants") or []
    )
    parameter_count = len(declared_params)
    if (declared_params or variant_entries) and params is None:
        errors.append(f"{label}: contract expects params, but the method schema has none")
    elif params is not None:
        for path in always_sent + may_send:
            if not nodes_at_path(document, params, path):
                errors.append(
                    f"{label}: RPCE sends params path {path!r}, "
                    "but the schema does not declare it"
                )
        errors.extend(
            consumed_path_errors(
                document,
                params,
                consumed_params,
                label=f"{label} params",
            )
        )
        if "alwaysSent" in check or "maySend" in check:
            missing_required = missing_required_sent_paths(
                document,
                params,
                always_sent=always_sent,
                may_send=may_send,
            )
            for name in missing_required:
                errors.append(
                    f"{label}: schema now requires param {name!r}, "
                    "but RPCE does not declare it as always sent"
                )

        for path, expected_values in sorted((check.get("enumValues") or {}).items()):
            expected = string_list(expected_values, label=f"{label}.enumValues.{path}")
            actual = enum_values_at_path(document, params, path)
            for value in expected:
                if value not in actual:
                    errors.append(
                        f"{label}: RPCE sends enum value {value!r} at {path!r}, "
                        f"but the schema allows {sorted(actual)!r}"
                    )

        sent_errors, sent_count = validate_param_variants(
            document,
            params,
            check.get("sentParamVariants"),
            label=label,
            direction="sent",
        )
        consumed_errors, consumed_count = validate_param_variants(
            document,
            params,
            check.get("consumedParamVariants"),
            label=label,
            direction="consumed",
        )
        errors.extend(sent_errors)
        errors.extend(consumed_errors)
        parameter_count += sent_count + consumed_count

    consumed_response = list(check.get("consumedResponse") or [])
    consumed_response_paths = [entry["path"] for entry in consumed_response]
    always_sent_response = string_list(
        check.get("alwaysSentResponse"), label=f"{label}.alwaysSentResponse"
    )
    may_send_response = string_list(
        check.get("maySendResponse"), label=f"{label}.maySendResponse"
    )
    declared_response = consumed_response_paths + always_sent_response + may_send_response
    response_schema = check.get("responseSchema")
    if (
        declared_response
        or check.get("responseEnumValues")
        or check.get("consumedEnumValues")
    ):
        response_document = load_json(schema_dir / response_schema)
        for entry in consumed_response:
            path = entry["path"]
            analysis = analyze_path(response_document, response_document, path)
            if not analysis.declared:
                errors.append(
                    f"{label}: RPCE consumes response path {path!r}, "
                    f"but {response_schema} does not declare it"
                )
                continue
            if analysis.presence != entry["presence"]:
                errors.append(
                    f"{label}: response path {path!r} presence changed from "
                    f"{entry['presence']!r} to {analysis.presence!r}"
                )
            if analysis.nullable != entry["nullable"]:
                errors.append(
                    f"{label}: response path {path!r} nullability changed from "
                    f"{entry['nullable']!r} to {analysis.nullable!r}"
                )

        for path in always_sent_response + may_send_response:
            if not nodes_at_path(response_document, response_document, path):
                errors.append(
                    f"{label}: RPCE sends response path {path!r}, "
                    f"but {response_schema} does not declare it"
                )
        if always_sent_response or may_send_response:
            missing_required = missing_required_sent_paths(
                response_document,
                response_document,
                always_sent=always_sent_response,
                may_send=may_send_response,
            )
            for name in missing_required:
                errors.append(
                    f"{label}: {response_schema} now requires response field {name!r}, "
                    "but RPCE does not declare it as always sent"
                )

        for path, expected_values in sorted((check.get("responseEnumValues") or {}).items()):
            expected = string_list(
                expected_values, label=f"{label}.responseEnumValues.{path}"
            )
            actual = enum_values_at_path(response_document, response_document, path)
            for value in expected:
                if value not in actual:
                    errors.append(
                        f"{label}: RPCE sends response enum value {value!r} at {path!r}, "
                        f"but {response_schema} allows {sorted(actual)!r}"
                    )

        for path, expected_values in sorted((check.get("consumedEnumValues") or {}).items()):
            expected = set(
                string_list(expected_values, label=f"{label}.consumedEnumValues.{path}")
            )
            actual = enum_values_at_path(response_document, response_document, path)
            if actual != expected:
                errors.append(
                    f"{label}: incoming enum {path!r} changed; "
                    f"RPCE handles {sorted(expected)!r}, schema allows {sorted(actual)!r}"
                )

    return errors, parameter_count, len(declared_response)


def validate_bundle(schema_dir: Path, contract: Mapping[str, Any]) -> tuple[list[str], dict[str, int]]:
    validate_contract(contract)
    checks = contract["methodChecks"]

    documents: dict[str, dict[str, Any]] = {}
    branch_indexes: dict[str, dict[str, Mapping[str, Any]]] = {}
    errors: list[str] = []
    parameter_paths = 0
    response_paths = 0
    for raw_check in checks:
        if not isinstance(raw_check, dict):
            raise GateError("each methodChecks entry must be an object")
        check_errors, params_count, response_count = validate_method_check(
            schema_dir, documents, branch_indexes, raw_check
        )
        errors.extend(check_errors)
        parameter_paths += params_count
        response_paths += response_count

    return sorted(errors), {
        "methods": len(checks),
        "parameterPaths": parameter_paths,
        "responsePaths": response_paths,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", default=os.environ.get("CODEX", "codex"))
    parser.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT)
    parser.add_argument(
        "--schema-dir",
        type=Path,
        help="validate an existing generated bundle (test/debug only; skips Codex invocation)",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        contract = load_json(args.contract)
        validate_contract(contract)
        minimum_version = parse_version(
            contract["minimumCodexVersion"], label="minimum Codex CLI"
        )
        experimental = contract["experimental"]

        installed_version: SemanticVersion | None = None
        generated_context: tempfile.TemporaryDirectory[str] | None = None
        if args.schema_dir is not None:
            schema_dir = args.schema_dir.resolve()
        else:
            installed_version, _version_output = installed_codex_version(args.codex)
            if installed_version < minimum_version:
                raise GateError(
                    f"installed Codex CLI {format_version(installed_version)} is below the "
                    f"contract floor {format_version(minimum_version)}. Install "
                    f"@openai/codex@{format_version(minimum_version)} or newer."
                )
            generated_context = tempfile.TemporaryDirectory(prefix="rpce-codex-app-server-schema-")
            schema_dir = Path(generated_context.name)
            generate_schema_bundle(args.codex, schema_dir, experimental=experimental)

        try:
            errors, counts = validate_bundle(schema_dir, contract)
        finally:
            if generated_context is not None:
                generated_context.cleanup()

        if errors:
            version_label = (
                format_version(installed_version)
                if installed_version is not None
                else "existing schema bundle"
            )
            print(
                f"ERROR: Codex app-server schema drift detected against {version_label}:",
                file=sys.stderr,
            )
            for error in errors:
                print(f"  - {error}", file=sys.stderr)
            print(
                "\nRegenerate with the intended Codex CLI, then update RPCE code and the "
                "bounded contract together. Do not copy or hand-edit the full upstream schema.",
                file=sys.stderr,
            )
            return 1

        version_label = (
            format_version(installed_version)
            if installed_version is not None
            else "existing schema bundle"
        )
        mode = "--experimental" if experimental else "stable methods only"
        print("Codex app-server schema gate passed.")
        print(f"  Codex CLI: {version_label}")
        print(f"  Contract floor: {format_version(minimum_version)}")
        print(f"  Generation mode: {mode}")
        print(
            "  Checked: "
            f"{counts['methods']} methods, "
            f"{counts['parameterPaths']} parameter paths, "
            f"{counts['responsePaths']} response paths"
        )
        return 0
    except GateError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
