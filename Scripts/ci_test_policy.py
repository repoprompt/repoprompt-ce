#!/usr/bin/env python3
"""Single source of truth for RepoPrompt CE CI test tiers."""

from __future__ import annotations

import re
from functools import lru_cache
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Mapping

CONTRACT_TIER = "contract"
INTEGRATION_TIER = "integration"
ALL_TIER = "all"
TIERS = (CONTRACT_TIER, INTEGRATION_TIER, ALL_TIER)
TESTS_ROOT = Path("Tests")
# Compatibility path used by synthetic policy tests that model the app target.
TEST_ROOT = TESTS_ROOT / "RepoPromptTests"


@dataclass(frozen=True)
class TestPolicyDecision:
    tier: str
    reason: str


@dataclass(frozen=True)
class SourceWaitOccurrence:
    path: Path
    line: int
    symbol: str
    suites: tuple[str, ...]


@dataclass(frozen=True)
class SourceTestPolicy:
    integration_reasons: Mapping[str, str]
    wait_occurrences: tuple[SourceWaitOccurrence, ...]
    unmapped_wait_occurrences: tuple[SourceWaitOccurrence, ...]


EXACT_INTEGRATION_REASONS: dict[str, str] = {
    "RepoPromptTests.AgentModeViewModelInactiveRefreshTests": (
        "mixed UI/session integration fixture with wall-clock polling"
    ),
    "RepoPromptTests.BackgroundComposeTabAdmissionTests": (
        "large workspace/session integration fixture with wall-clock polling"
    ),
    "RepoPromptTests.CodexFallbackFIFOTests": (
        "host configuration and persisted-setting integration coverage"
    ),
    "RepoPromptTests.ContextBuilderRunLifecycleTests": (
        "real MCP, process, global-setting, and teardown lifecycle coverage"
    ),
    "RepoPromptTests.DebugProcessMemorySamplerTests": (
        "host process and memory sampling diagnostics"
    ),
    "RepoPromptTests.DirectHeadlessStdioTransportTests": (
        "real stdio subprocess transport coverage"
    ),
    "RepoPromptTests.GitBlobIdentityServiceTests": (
        "host Git subprocess and filesystem integration coverage"
    ),
    "RepoPromptTests.GitWorktreeInitializationAPITests": (
        "real Git worktree and subprocess integration coverage"
    ),
    "RepoPromptTests.WorkspaceRootNamespaceManifestTests": (
        "filesystem scale and spill-path integration coverage"
    ),
    "RepoPromptTests.WorkspaceRootTargetEvidenceCoordinatorTests": (
        "filesystem/Git coordination integration coverage"
    ),
    "RepoPromptTests.WorkspaceSwitchRecoveryTests": (
        "assembled workspace recovery and persisted-state integration coverage"
    ),
    "RepoPromptTests.WorktreeAPISmokeHarnessTests": (
        "assembled worktree smoke harness with host process lifecycle"
    ),
}


# The deleted runner had to execute these classes one method per process to keep
# them alive. That is historical evidence of host/process coupling, not a
# deterministic pull-request contract. Preserve the evidence after removing the
# workaround so it cannot quietly regain merge-veto power.
HISTORICALLY_METHOD_ISOLATED_SUITES: frozenset[str] = frozenset(
    {
        "RepoPromptTests.AgentModeRunServiceLifecycleTests",
        "RepoPromptTests.AgentModeTranscriptProjectionSharedSubscriptionTests",
        "RepoPromptTests.AgentModeViewModelSharedSubscriptionTests",
        "RepoPromptTests.AgentRunWorktreeStartGitSeedTestCase",
        "RepoPromptTests.CLIProcessRunnerLifecycleTests",
        "RepoPromptTests.ClaudeAgentModeCoordinatorLifecycleTests",
        "RepoPromptTests.CodexAgentModeCoordinatorLivenessTests",
        "RepoPromptTests.CodexAppServerClientDisconnectTests",
        "RepoPromptTests.CodexAppServerClientProcessExitTests",
        "RepoPromptTests.CodexFallbackFIFOTests",
        "RepoPromptTests.CodexMCPBootstrapReadinessTests",
        "RepoPromptTests.CodexMCPRoutingReadinessTests",
        "RepoPromptTests.ContextBuilderMCPProgressTimelineTests",
        "RepoPromptTests.ContextBuilderNestedMCPFailureTests",
        "RepoPromptTests.ContextBuilderWorktreeInheritanceTests",
        "RepoPromptTests.DirectHeadlessCompositionTests",
        "RepoPromptTests.DirectHeadlessProcessTests",
        "RepoPromptTests.DirectHeadlessRuntimeConfigurationTests",
        "RepoPromptTests.DirectHeadlessStdioTransportTests",
        "RepoPromptTests.GitProcessTimeoutTests",
        "RepoPromptTests.GrokBuildCLIProviderProcessTests",
        "RepoPromptTests.MCPSocketDescriptorHardeningTests",
        "RepoPromptTests.ProcessTerminationExitStatusTests",
        "RepoPromptTests.RepoPromptAgentCodexRateLimitsSnapshotIsolationTests",
        "RepoPromptTests.TextCodexRateLimitsSnapshotStoreIsolationTests",
        "RepoPromptTests.WorktreeAPISmokeHarnessTests",
    }
)

# These markers must describe the suite itself, immediately before the XCTest
# suffix. A word appearing in the middle of a deterministic suite name (for
# example, CodexIntegrationConfigurationTests) is not enough to quarantine it.
INTEGRATION_CLASS_PATTERNS: tuple[tuple[re.Pattern[str], str], ...] = (
    (
        re.compile(r"(?:Integration|EndToEnd)(?:Tests|TestCase)$"),
        "assembled integration/end-to-end fixture",
    ),
    (
        re.compile(r"(?:Benchmark|Performance)(?:Tests|TestCase)$"),
        "measurement workload; diagnostics are not pull-request contracts",
    ),
    (
        re.compile(
            r"(?:Instrumentation|DebugHarness|Diagnostics)(?:Tests|TestCase)$"
        ),
        "runtime instrumentation or diagnostics harness",
    ),
    (
        re.compile(r"(?:SmokeHarness|LiveSmoke|LiveHarness)(?:Tests|TestCase)$"),
        "assembled live/smoke harness",
    ),
)

CONTRACT_REPLACEMENTS: dict[str, tuple[str, ...]] = {
    "RepoPromptTests.ContextBuilderRunLifecycleTests": (
        "RepoPromptTests.ContextBuilderRunStateContractTests",
    ),
    "RepoPromptTests.BackgroundComposeTabAdmissionTests": (
        "RepoPromptTests.AgentSessionLifecycleAuthorityContractTests",
    ),
}

TEST_TYPE_RE = re.compile(
    r"\b(?:private\s+|fileprivate\s+|internal\s+|public\s+|open\s+)?"
    r"(?:final\s+)?(?:class|struct|actor)\s+"
    r"([A-Za-z_][A-Za-z0-9_]*(?:Tests|TestCase))\b"
)
TEST_EXTENSION_RE = re.compile(
    r"\bextension\s+([A-Za-z_][A-Za-z0-9_]*(?:Tests|TestCase))\b"
)

# Timer-bearing files without a declared XCTest suite are violations unless
# they are one of these exact support files. Keep this list path-based and give
# every exception a concrete role; directory membership or a Support suffix is
# never sufficient authority.
EXPLICIT_TEST_SUPPORT_REASONS: Mapping[str, str] = {
    "Tests/RepoPromptTests/Helpers/AgentRunSessionStoreTestSupport.swift": (
        "shared agent-run session-store readiness helper"
    ),
    "Tests/RepoPromptTests/Helpers/AsyncTestCondition.swift": (
        "shared asynchronous condition wait primitive"
    ),
    "Tests/RepoPromptTests/Helpers/CodemapSeamTestSupport.swift": (
        "shared codemap seam and readiness fixtures"
    ),
    "Tests/RepoPromptTests/Helpers/CodexHookReviewTestSupport.swift": (
        "shared Codex hook review completion helper"
    ),
    "Tests/RepoPromptTests/Helpers/GitWorktreeTestSupport.swift": (
        "shared host Git worktree cleanup helper"
    ),
    "Tests/RepoPromptTests/Helpers/TestHangHardenedFences.swift": (
        "shared bounded coordination fences for integration fixtures"
    ),
    "Tests/RepoPromptTests/MCP/Control/MCPSharedServerTestLease.swift": (
        "process-wide MCP shared-server lease arbitration helper"
    ),
    "Tests/RepoPromptTests/Persistence/DurableArtifacts/DurableArtifactTestSupport.swift": (
        "filesystem timestamp stabilization helper for durable-artifact fixtures"
    ),
}

# These primitives make the clock part of the assertion. They are useful in an
# integration/soak lane, but they do not get veto power over unrelated PRs.
SOURCE_INTEGRATION_PRIMITIVES: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("Task.sleep", re.compile(r"\bTask\.sleep\s*\(")),
    ("Thread.sleep", re.compile(r"\bThread\.sleep\s*\(")),
    ("usleep", re.compile(r"\busleep\s*\(")),
    ("asyncAfter", re.compile(r"\.asyncAfter\s*\(")),
    ("AsyncTestWait", re.compile(r"\bAsyncTestWait\.")),
)


def suite_class_name(suite: str) -> str:
    return suite.rsplit(".", 1)[-1]


def test_target_name(path: Path, repository_root: Path) -> str | None:
    try:
        relative_path = path.relative_to(repository_root / TESTS_ROOT)
    except ValueError:
        return None
    if len(relative_path.parts) < 2:
        return None
    target_name = relative_path.parts[0]
    return target_name if target_name.endswith("Tests") else None


def test_suites_in_source(
    source: str,
    path: Path,
    repository_root: Path,
) -> tuple[str, ...]:
    target_name = test_target_name(path, repository_root)
    if target_name is None:
        return ()

    class_names = set(TEST_TYPE_RE.findall(source))
    class_names.update(TEST_EXTENSION_RE.findall(source))
    class_names.discard("XCTestCase")
    return tuple(
        f"{target_name}.{class_name}"
        for class_name in sorted(class_names)
    )


def explicit_test_support_reason(
    path: Path,
    repository_root: Path,
) -> str | None:
    try:
        relative_path = path.relative_to(repository_root).as_posix()
    except ValueError:
        return None
    return EXPLICIT_TEST_SUPPORT_REASONS.get(relative_path)


def matching_lines(source: str, pattern: re.Pattern[str]) -> tuple[int, ...]:
    return tuple(
        source.count("\n", 0, match.start()) + 1
        for match in pattern.finditer(source)
    )


def scan_source_test_policy(repository_root: Path) -> SourceTestPolicy:
    tests_root = repository_root / TESTS_ROOT
    if not tests_root.is_dir():
        raise FileNotFoundError(f"missing tests root: {tests_root}")

    occurrences: list[SourceWaitOccurrence] = []
    unmapped: list[SourceWaitOccurrence] = []
    occurrences_by_suite: dict[str, list[SourceWaitOccurrence]] = {}

    for path in sorted(tests_root.rglob("*.swift")):
        source = path.read_text(encoding="utf-8")
        file_occurrences: set[tuple[str, int]] = set()
        for symbol, pattern in SOURCE_INTEGRATION_PRIMITIVES:
            file_occurrences.update(
                (symbol, line)
                for line in matching_lines(source, pattern)
            )
        if not file_occurrences:
            continue

        suites = test_suites_in_source(source, path, repository_root)
        for symbol, line in sorted(file_occurrences, key=lambda item: (item[1], item[0])):
            occurrence = SourceWaitOccurrence(
                path=path,
                line=line,
                symbol=symbol,
                suites=suites,
            )
            occurrences.append(occurrence)
            if not suites:
                unmapped.append(occcurrence)
            for suite in suites:
                occurrences_by_suite.setdefault(suite, []).append(occurrence)

    reasons: dict[str, str] = {}
    for suite, suite_occurrences in sorted(occurrences_by_suite.items()):
        symbols = sorted({occurrence.symbol for occurrence in suite_occurrences})
        paths = sorted(
            {
                occurrence.path.relative_to(repository_root).as_posix()
                for occurrence in suite_occurrences
            }
        )
        reasons[suite] = (
            "source uses wall-clock/polling primitive(s) "
            f"{', '.join(symbols)} in {', '.join(paths)}"
        )

    return SourceTestPolicy(
        integration_reasons=reasons,
        wait_occurrences=tuple(occurrences),
        unmapped_wait_occurrences=tuple(unmapped),
    )


@lru_cache(maxsize=1)
def repository_source_integration_reasons() -> Mapping[str, str]:
    repository_root = Path(__file__).resolve().parents[1]
    try:
        return scan_source_test_policy(repository_root).integration_reasons
    except FileNotFoundError:
        return {}


def classify_suite(
    suite: str,
    source_integration_reasons: Mapping[str, str] | None = None,
) -> TestPolicyDecision:
    # Precedence is deliberate: reviewed exact evidence, historical isolation
    # evidence, current source primitives, narrow semantic naming, then contract.
    exact_reason = EXACT_INTEGRATION_REASONS.get(suite)
    if exact_reason is not None:
        return TestPolicyDecision(INTEGRATION_TIER, exact_reason)

    if suite in HISTORICALLY_METHOD_ISOLATED_SUITES:
        return TestPolicyDecision(
            INTEGRATION_TIER,
            "historically required one-method-per-process CI isolation",
        )

    effective_source_reasons = (
        source_integration_reasons
        if source_integration_reasons is not None
        else repository_source_integration_reasons()
    )
    source_reason = effective_source_reasons.get(suite)
    if source_reason is not None:
        return TestPolicyDecision(INTEGRATION_TIER, source_reason)

    class_name = suite_class_name(suite)
    for pattern, reason in INTEGRATION_CLASS_PATTERNS:
        if pattern.search(class_name):
            return TestPolicyDecision(INTEGRATION_TIER, reason)

    return TestPolicyDecision(
        CONTRACT_TIER,
        "deterministic pull-request coverage",
    )


def suites_for_tier(
    suites: Iterable[str],
    tier: str,
    source_integration_reasons: Mapping[str, str] | None = None,
) -> tuple[str, ...]:
    if tier not in TIERS:
        raise ValueError(f"unknown test tier: {tier}")
    suite_list = tuple(sorted(set(suites)))
    if tier == ALL_TIER:
        return suite_list
    return tuple(
        suite
        for suite in suite_list
        if classify_suite(suite, source_integration_reasons).tier == tier
    )


def partition_suites(
    suites: Iterable[str],
    source_integration_reasons: Mapping[str, str] | None = None,
) -> tuple[tuple[str, ...], tuple[str, ...]]:
    suite_list = tuple(sorted(set(suites)))
    return (
        suites_for_tier(
            suite_list,
            CONTRACT_TIER,
            source_integration_reasons,
        ),
        suites_for_tier(
            suite_list,
            INTEGRATION_TIER,
            source_integration_reasons,
        ),
    )
