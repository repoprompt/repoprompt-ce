#!/usr/bin/env python3
"""Ownership enforcement for Overseer full-access versus restricted authorization.

`OverseerAuthorizationEngine` is the single decision owner. This checker proves, for production
Swift sources, that:

1. only the engine evaluates the master-setting input, and only the runtime default reads storage;
2. every permission-gate consultation outside the engine (`waives(.gate)` /
   `waivesTargetOwnership(.gate, ...)`) is pinned by an exact manifest of (file, gate, count) rows, so
   a caller cannot quietly add, drop, or rename a gate decision;
3. the restricted scope authority entry point is invoked only by the engine;
4. the restricted operation authorizer is invoked only by the engine;
5. retired parallel policy names are gone.

Comments are stripped before matching. `--self-test` plants one violation per rule in a temporary
tree and requires each to be reported.
"""

from __future__ import annotations

import re
import sys
import tempfile
from collections import Counter
from pathlib import Path

ENGINE = "Sources/RepoPrompt/Features/AgentMode/Runtime/Delegation/OverseerAuthorizationEngine.swift"
ENGINE_DIR = "Sources/RepoPrompt/Features/AgentMode/Runtime/Delegation/"


def is_engine(rel: str) -> bool:
    """The engine owner: `OverseerAuthorizationEngine.swift` and its `+Family.swift` extensions."""
    name = rel[len(ENGINE_DIR):] if rel.startswith(ENGINE_DIR) else ""
    return name == "OverseerAuthorizationEngine.swift" or (
        name.startswith("OverseerAuthorizationEngine+") and name.endswith(".swift") and "/" not in name
    )
RUNTIME = "Sources/RepoPrompt/Features/AgentMode/Runtime/Delegation/DelegationScopeRuntime.swift"
MANIFEST = "Scripts/overseer_authorization_manifest.tsv"

GATE_CALL = re.compile(r"\bwaives(?:TargetOwnership)?\(\s*\.([A-Za-z_][A-Za-z0-9_]*)")
SETTING_INPUT = re.compile(r"\bisGlobalAutoApproveEnabled\(\)")
SETTING_STORAGE = re.compile(r"\bOverseerGlobalAutoApprove\.isEnabled\(\)")
SCOPE_AUTHORITY_ENTRY = re.compile(r"\.authorize\(\s*DomainDelegationScopeAuthorizationRequest\(")
OPERATION_AUTHORIZER = re.compile(r"\bDomainAgentSessionOperationAuthorizer\.authorize\(")
ENGINE_ONLY_ALGORITHMS = re.compile(
    r"\bDomainDelegationScopeLinkPolicy\.missingCapability\(|\badoptionGuardrailViolation\(|\.evaluateCreationGuardrails\(scopeID:"
    r"|\bDomainDelegationScopePlacementPolicy\.(?:validateReparent|validateAdopt|depthViolation)\("
    r"|\bDomainDelegationScopeAuthorizationRequest\(|\bDomainDelegationScopeAuthority\.isValid\("
    r"|\bDomainAgentSessionLinkCapabilityElevation\(|\.elevate\(observer:"
)
# The setting input may be named only by its owner (the runtime declares it; the engine reads it), so
# an alias such as `let read = scopes.isGlobalAutoApproveEnabled` elsewhere fails too.
SETTING_INPUT_NAME = re.compile(r"\bisGlobalAutoApproveEnabled\b")
# The all-sessions capability ceiling is decided by the engine; the runtime uses it only for the
# user's own approval card ("Grant all for this session").
ALL_SESSIONS_CEILING = re.compile(r"\ballSessionsPermitted\b")
RETIRED = re.compile(r"\bOverseerPermissionPolicy\b|\b(?:scopes|delegationScopes|runtime)\.permissionPolicy\b")



def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    return "\n".join(_strip_line_comment(line) for line in text.split("\n"))


def _strip_line_comment(line: str) -> str:
    in_string = False
    i = 0
    while i < len(line):
        ch = line[i]
        if ch == "\\" and in_string:
            i += 2
            continue
        if ch == '"':
            in_string = not in_string
        elif not in_string and line.startswith("//", i):
            return line[:i]
        i += 1
    return line


def production_sources(root: Path) -> list[tuple[str, str]]:
    result = []
    for base in ("Sources/RepoPrompt",):
        for path in sorted((root / base).rglob("*.swift")):
            rel = path.relative_to(root).as_posix()
            result.append((rel, strip_comments(path.read_text(encoding="utf-8"))))
    return result


def read_manifest(root: Path) -> Counter:
    rows: Counter = Counter()
    manifest = root / MANIFEST
    if not manifest.exists():
        return rows
    for raw in manifest.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        path, gate, count = line.split("\t")
        rows[(path, gate)] = int(count)
    return rows


def check(root: Path) -> list[str]:
    errors: list[str] = []
    observed: Counter = Counter()
    for rel, text in production_sources(root):
        if SETTING_INPUT.search(text) and rel != ENGINE:
            errors.append(f"{rel}: only OverseerAuthorizationEngine may evaluate isGlobalAutoApproveEnabled()")
        if SETTING_INPUT_NAME.search(text) and rel not in (ENGINE, RUNTIME):
            errors.append(f"{rel}: the setting input is named only by DelegationScopeRuntime and the engine")
        if ALL_SESSIONS_CEILING.search(text) and not is_engine(rel) and rel != RUNTIME:
            errors.append(f"{rel}: the all-sessions capability ceiling is decided by OverseerAuthorizationEngine")
        if SETTING_STORAGE.search(text) and rel != RUNTIME:
            errors.append(f"{rel}: read Overseer full access through OverseerAuthorizationEngine, not OverseerGlobalAutoApprove.isEnabled()")
        if SCOPE_AUTHORITY_ENTRY.search(text) and not is_engine(rel):
            errors.append(f"{rel}: only OverseerAuthorizationEngine may run the restricted scope authority")
        if OPERATION_AUTHORIZER.search(text) and not is_engine(rel):
            errors.append(f"{rel}: only OverseerAuthorizationEngine may run the restricted operation authorizer")
        if ENGINE_ONLY_ALGORITHMS.search(text) and not is_engine(rel):
            errors.append(f"{rel}: restricted permission algorithm outside OverseerAuthorizationEngine")
        if RETIRED.search(text):
            errors.append(f"{rel}: retired parallel policy name; use OverseerAuthorizationEngine")
        if is_engine(rel):
            continue
        for gate in GATE_CALL.findall(text):
            observed[(rel, gate)] += 1
    expected = read_manifest(root)
    for key in sorted(set(observed) | set(expected)):
        if observed[key] != expected[key]:
            path, gate = key
            errors.append(
                f"{path}: gate .{gate} consulted {observed[key]}x, manifest pins {expected[key]}x "
                f"(update {MANIFEST} only when the engine owner intentionally delegates this decision)"
            )
    return errors


def self_test() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        src = root / "Sources/RepoPrompt/Features/Example.swift"
        src.parent.mkdir(parents=True)
        (root / "Scripts").mkdir()
        (root / MANIFEST).write_text("Sources/RepoPrompt/Features/Example.swift\tscopeCoverage\t1\n", encoding="utf-8")
        src.write_text(
            "\n".join([
                "let a = scopes.isGlobalAutoApproveEnabled()",
                "let b = OverseerGlobalAutoApprove.isEnabled()",
                "let c = scopes.authorize(DomainDelegationScopeAuthorizationRequest(x))",
                "let d = DomainAgentSessionOperationAuthorizer.authorize(op)",
                "let e = OverseerPermissionPolicy.current",
                "let e2 = scopes.permissionPolicy",
                "let f = engine.waives(.linkRequired)",
                "let h = DomainDelegationScopeLinkPolicy.missingCapability(linkCapabilities: m, grant: g)",
                "let request = DomainDelegationScopeAuthorizationRequest(operation: op)",
                "let reader = scopes.isGlobalAutoApproveEnabled",
                "let ok = DomainDelegationScopeAuthority.isValid(proof, for: grant, targetSessionID: id)",
                "let caps = DomainDelegationScopeCapability.allSessionsPermitted",
                "elevation.elevate(observer: id)",
                "// let g = engine.waives(.humanOnlyForAgent) stays ignored inside a comment",
            ]),
            encoding="utf-8",
        )
        errors = check(root)
        expectations = [
            "may evaluate isGlobalAutoApproveEnabled",
            "not OverseerGlobalAutoApprove.isEnabled",
            "restricted scope authority",
            "restricted operation authorizer",
            "retired parallel policy name",
            "restricted permission algorithm outside",
            "setting input is named only",
            "all-sessions capability ceiling",
            "gate .linkRequired consulted 1x, manifest pins 0x",
            "gate .scopeCoverage consulted 0x, manifest pins 1x",
        ]
        missing = [e for e in expectations if not any(e in err for err in errors)]
        unexpected = [err for err in errors if "humanOnlyForAgent" in err]
        if missing or unexpected:
            print("overseer authorization guardrail self-test failed", file=sys.stderr)
            for item in missing:
                print(f"  not detected: {item}", file=sys.stderr)
            for item in unexpected:
                print(f"  comment matched: {item}", file=sys.stderr)
            return 1
    return 0


def main() -> int:
    if "--self-test" in sys.argv[1:]:
        return self_test()
    root = Path(__file__).resolve().parent.parent
    if self_test() != 0:
        return 1
    errors = check(root)
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    if errors:
        return 1
    print("Overseer authorization ownership guardrails passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
