#!/usr/bin/env python3
"""Deterministic hosted CI runner for RepoPrompt CE XCTest suites."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable, Mapping, Optional, Sequence, TextIO

from modularization_ci_artifact import validate as validate_ci_artifact
from swift_imports import sources_import_module
from ci_test_coverage import listed_tests, listing_digest, verify_execution

XCTEST_BUNDLE_GLOB = "*.xctest"
SANDBOX_MARKER_NAME = ".issue944-test-sandbox"
CommandExecutor = Callable[[Sequence[str], Optional[Path], Mapping[str, str]], int]


@dataclass(frozen=True)
class ShardSelection:
    suites: tuple[str, ...]
    method_loads: tuple[int, ...]


@dataclass(frozen=True)
class BundleSelection:
    package_bundle: Path | None
    target_bundles: Mapping[str, Path]
    xctest_binary: tuple[str, ...] | None


def parse_suite_methods(list_output: str) -> dict[str, tuple[str, ...]]:
    methods_by_suite: dict[str, set[str]] = {}
    for raw_line in list_output.splitlines():
        line = raw_line.strip()
        if "/" not in line:
            continue
        suite, method = line.split("/", 1)
        if not suite or not method:
            continue
        methods_by_suite.setdefault(suite, set()).add(line)
    return {
        suite: tuple(sorted(methods_by_suite[suite]))
        for suite in sorted(methods_by_suite)
    }


def list_suite_methods(
    swift_binary: str,
    cwd: Path | None,
    *,
    skip_build: bool = False,
) -> dict[str, tuple[str, ...]]:
    result = subprocess.run(
        [swift_binary, "test", "list", *(["--skip-build"] if skip_build else [])],
        check=True,
        capture_output=True,
        cwd=cwd,
        text=True,
    )
    return parse_suite_methods(result.stdout)


def validate_shard_args(shard_count: int, shard_index: int) -> None:
    if shard_count <= 0:
        raise ValueError("--shard-count must be greater than zero")
    if shard_index < 1 or shard_index > shard_count:
        raise ValueError("--shard-index must be between 1 and --shard-count")


def assign_suites_to_shards(
    method_counts: Mapping[str, int],
    shard_count: int,
) -> tuple[tuple[tuple[str, ...], ...], tuple[int, ...]]:
    if shard_count <= 0:
        raise ValueError("shard_count must be greater than zero")

    shards: list[list[str]] = [[] for _ in range(shard_count)]
    loads = [0 for _ in range(shard_count)]
    ordered_suites = sorted(
        method_counts.items(),
        key=lambda item: (-item[1], item[0]),
    )
    for suite, method_count in ordered_suites:
        if method_count <= 0:
            raise ValueError(f"discovered suite {suite} has no test methods")
        shard = min(range(shard_count), key=lambda index: (loads[index], index))
        shards[shard].append(suite)
        loads[shard] += method_count

    return (
        tuple(tuple(sorted(shard)) for shard in shards),
        tuple(loads),
    )


def select_shard(
    method_counts: Mapping[str, int],
    *,
    shard_count: int,
    shard_index: int,
) -> ShardSelection:
    validate_shard_args(shard_count, shard_index)
    shards, loads = assign_suites_to_shards(method_counts, shard_count)
    return ShardSelection(shards[shard_index - 1], loads)


def test_target_for_suite(suite: str) -> str:
    return suite.split(".", 1)[0]


def scratch_path_args(scratch_path: Path | None) -> tuple[str, ...]:
    return ("--scratch-path", str(scratch_path)) if scratch_path is not None else ()


def discover_test_bundles(
    swift_binary: str,
    cwd: Path | None,
    scratch_path: Path | None = None,
    prebuilt_bin_path: Path | None = None,
) -> dict[str, Path]:
    if prebuilt_bin_path is not None:
        bin_path = prebuilt_bin_path
    else:
        try:
            result = subprocess.run(
                [swift_binary, "build", *scratch_path_args(scratch_path), "--show-bin-path"],
                check=True,
                capture_output=True,
                cwd=cwd,
                text=True,
            )
        except (OSError, subprocess.CalledProcessError):
            return {}
        bin_path = Path(result.stdout.strip())
    if not bin_path.is_dir():
        return {}
    return {
        path.name.removesuffix(".xctest"): path
        for path in sorted(bin_path.glob(XCTEST_BUNDLE_GLOB))
    }


def package_test_bundle(discovered: Mapping[str, Path]) -> Path | None:
    matches = [
        path
        for name, path in discovered.items()
        if name.endswith("PackageTests")
    ]
    return matches[0] if len(matches) == 1 else None


def target_bundles_for_suites(
    discovered: Mapping[str, Path],
    suites: Iterable[str],
) -> dict[str, Path]:
    targets = {test_target_for_suite(suite) for suite in suites}
    return {
        target: discovered[target]
        for target in sorted(targets)
        if target in discovered
    }


def xctest_binary_path() -> tuple[str, ...]:
    try:
        result = subprocess.run(
            ["xcrun", "--find", "xctest"],
            check=True,
            capture_output=True,
            text=True,
        )
        path = result.stdout.strip()
        if path:
            return (path,)
    except (OSError, subprocess.CalledProcessError):
        pass
    return ("xcrun", "xctest")


def resolve_bundle_selection(
    *,
    swift_binary: str,
    cwd: Path | None,
    suites: Sequence[str],
    prebuilt_bin_path: Path | None = None,
) -> BundleSelection:
    discovered = discover_test_bundles(swift_binary, cwd, prebuilt_bin_path=prebuilt_bin_path)
    if not discovered:
        return BundleSelection(None, {}, None)
    if len(discovered) == 1:
        return BundleSelection(next(iter(discovered.values())), {}, xctest_binary_path())

    package_bundle = package_test_bundle(discovered)
    if package_bundle is not None:
        return BundleSelection(package_bundle, {}, xctest_binary_path())

    target_bundles = target_bundles_for_suites(discovered, suites)
    missing_targets = sorted(
        {
            test_target_for_suite(suite)
            for suite in suites
            if test_target_for_suite(suite) not in target_bundles
        }
    )
    if missing_targets:
        raise ValueError(
            f"missing XCTest bundles for selected targets: {missing_targets}; "
            f"available bundles: {sorted(discovered)}"
        )
    return BundleSelection(None, target_bundles, xctest_binary_path())


def bundle_for_suite(
    suite: str,
    selection: BundleSelection,
) -> Path | None:
    if selection.package_bundle is not None:
        return selection.package_bundle
    return selection.target_bundles.get(test_target_for_suite(suite))


def command_for_suite(
    suite: str,
    *,
    swift_binary: str,
    bundle_selection: BundleSelection,
) -> tuple[str, ...]:
    bundle = bundle_for_suite(suite, bundle_selection)
    if bundle is not None:
        xctest_binary = bundle_selection.xctest_binary or ("xcrun", "xctest")
        return (*xctest_binary, "-XCTest", suite, str(bundle))
    return (swift_binary, "test", "--skip-build", "--filter", suite)


def isolated_suite_environment(
    sandbox_root: Path,
    suite: str,
    base_environment: Mapping[str, str] | None = None,
) -> dict[str, str]:
    digest = hashlib.sha256(suite.encode("utf-8")).hexdigest()[:16]
    suite_root = sandbox_root / digest
    home = suite_root / "home"
    temporary = suite_root / "tmp"
    config = suite_root / "config"
    cache = suite_root / "cache"
    data = suite_root / "data"
    for directory in (home, temporary, config, cache, data):
        directory.mkdir(parents=True, exist_ok=True)
    (suite_root / SANDBOX_MARKER_NAME).touch(exist_ok=True)

    environment = dict(base_environment or os.environ)
    environment.update(
        {
            "HOME": str(home),
            "CFFIXED_USER_HOME": str(home),
            "TMPDIR": str(temporary),
            "TMP": str(temporary),
            "TEMP": str(temporary),
            "XDG_CONFIG_HOME": str(config),
            "XDG_CACHE_HOME": str(cache),
            "XDG_DATA_HOME": str(data),
            "REPOPROMPT_TEST_SANDBOX_ROOT": str(suite_root),
            "NSUnbufferedIO": "YES",
        }
    )
    return environment


def execute_command(
    command: Sequence[str],
    cwd: Path | None,
    environment: Mapping[str, str],
) -> int:
    try:
        return subprocess.run(
            list(command),
            check=False,
            cwd=cwd,
            env=dict(environment),
        ).returncode
    except OSError as error:
        print(f"Unable to launch {command[0]}: {error}", file=sys.stderr)
        return 127


XCTEST_HELPER_RELATIVE_PATH = Path("libexec/swift/pm/swiftpm-xctest-helper")
SWIFT_TESTING_HELPER_RELATIVE_PATH = Path("libexec/swift/pm/swiftpm-testing-helper")
# Swift Testing's EXIT_NO_TESTS_FOUND (EX_UNAVAILABLE); `swift test` treats it as success.
SWIFT_TESTING_NO_TESTS_EXIT = 69
BundleTestLister = Callable[[Path, Mapping[str, str]], Optional[list[str]]]


def sources_import_swift_testing(directory: Path) -> bool:
    """Whether any Swift file under `directory` imports Testing; unreadable files count as yes."""
    if not directory.is_dir():
        return False
    return sources_import_module(directory, "Testing")


def package_uses_swift_testing(root: Path) -> bool:
    """Direct XCTest execution would silently skip Swift Testing tests, so detect them."""
    return sources_import_swift_testing(root / "Tests")


def toolchain_helper_path(swift_binary: str, relative_path: Path) -> Path | None:
    try:
        result = subprocess.run(
            ["xcrun", "--find", swift_binary],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    swift_path = Path(result.stdout.strip())
    helper = swift_path.parent.parent / relative_path
    return helper if helper.is_file() else None


def xctest_helper_path(swift_binary: str) -> Path | None:
    return toolchain_helper_path(swift_binary, XCTEST_HELPER_RELATIVE_PATH)


def swift_testing_helper_path(swift_binary: str) -> Path | None:
    return toolchain_helper_path(swift_binary, SWIFT_TESTING_HELPER_RELATIVE_PATH)


def swift_testing_command(helper: Path, bundle: Path, test_filter: str | None) -> tuple[str, ...]:
    """The `swift test --build-system swiftbuild` invocation of swiftpm-testing-helper, verbatim.

    Captured from SwiftPM 6.3.3's own process arguments. SwiftPM forwards `--filter` unchanged to
    Swift Testing, so passing it through keeps Swift Testing selection identical by construction.
    """
    binary = str(bundle / "Contents" / "MacOS" / bundle.stem)
    filter_arguments = ("--filter", test_filter) if test_filter else ()
    return (
        str(helper), "--test-bundle-path", binary, "--build-system", "swiftbuild",
        *filter_arguments, binary, "--testing-library", "swift-testing",
    )


def developer_library_environment(base: Mapping[str, str]) -> dict[str, str] | None:
    """Add the platform Developer frameworks that `swift test` exposes to test processes.

    The helper dlopens the bundle, which links XCTest and Testing through @rpath; without these
    paths the load fails. Returns None when the platform path cannot be resolved.
    """
    try:
        result = subprocess.run(
            ["xcrun", "--show-sdk-platform-path"], check=True, capture_output=True, text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    developer = Path(result.stdout.strip()) / "Developer"
    if not developer.is_dir():
        return None
    additions = {
        "DYLD_FRAMEWORK_PATH": [developer / "Library/Frameworks", developer / "Library/PrivateFrameworks"],
        "DYLD_LIBRARY_PATH": [developer / "usr/lib"],
    }
    environment = dict(base)
    for key, paths in additions.items():
        entries = [str(path) for path in paths]
        if environment.get(key):
            entries.append(environment[key])
        environment[key] = ":".join(entries)
    return environment


def flatten_listed_tests(document: Mapping[str, object]) -> list[str]:
    """Flatten swiftpm-xctest-helper JSON into SwiftPM `Module.Class/method` specifiers."""
    specifiers: list[str] = []

    def is_leaf(node: object) -> bool:
        # Test methods carry no "tests" key; suites always do, even when empty ("tests": []).
        return isinstance(node, Mapping) and "tests" not in node

    def visit(node: Mapping[str, object]) -> None:
        children = node.get("tests")
        if not isinstance(children, list) or not children:
            return
        name = str(node.get("name", ""))
        if all(is_leaf(child) for child in children):
            specifiers.extend(f"{name}/{child.get('name')}" for child in children if child.get("name"))
            return
        for child in children:
            if isinstance(child, Mapping):
                visit(child)

    visit(document)
    return sorted(set(specifiers))


def helper_bundle_lister(helper: Path) -> BundleTestLister:
    def list_tests(bundle: Path, environment: Mapping[str, str]) -> Optional[list[str]]:
        with tempfile.TemporaryDirectory(prefix="rpce-test-list-") as directory:
            output = Path(directory) / "tests.json"
            try:
                subprocess.run(
                    [str(helper), str(bundle), str(output)],
                    check=True,
                    capture_output=True,
                    env=dict(environment),
                )
                return flatten_listed_tests(json.loads(output.read_text(encoding="utf-8")))
            except (OSError, subprocess.CalledProcessError, ValueError):
                return None

    return list_tests


def is_portable_filter(test_filter: str) -> bool:
    """Whether Python `re` and SwiftPM's ICU regex (NSRegularExpression) agree on this filter.

    Accepts literals, escaped punctuation, `.`, `*`, `+`, `?`, `|`, anchors, plain groups, and
    simple character classes. Rejects the constructs whose syntax or meaning differs between the
    two engines: `\\<letter or digit>` escapes, `(?…)` groups, `{}` intervals, and nested or
    set-operation (`[[`, `&&`, `--`) and leading-`]` character classes.
    """
    in_class = False
    index = 0
    while index < len(test_filter):
        character = test_filter[index]
        if character == "\\":
            if index + 1 >= len(test_filter) or test_filter[index + 1].isalnum():
                return False
            index += 2
            continue
        if character in "{}":
            return False
        if in_class:
            if character == "[" or test_filter.startswith(("&&", "--"), index):
                return False
            if character == "]":
                in_class = False
        elif character == "[":
            if test_filter.startswith(("]", "^]"), index + 1):
                return False
            in_class = True
        elif test_filter.startswith("(?", index):
            return False
        index += 1
    if in_class:
        return False
    try:
        re.compile(test_filter)
    except re.error:
        return False
    return True


def select_xctest_specifiers(specifiers: Sequence[str], test_filter: str | None) -> list[str] | None:
    """Apply SwiftPM `--filter` regex semantics; collapse fully selected suites.

    Returns None when equivalence with SwiftPM's matching is not guaranteed (see
    `is_portable_filter`) so callers can fall back to SwiftPM or fail closed.
    """
    if not test_filter:
        return ["All"] if specifiers else []
    if not is_portable_filter(test_filter):
        return None
    pattern = re.compile(test_filter)
    selected = [specifier for specifier in specifiers if pattern.search(specifier)]
    by_suite: dict[str, list[str]] = {}
    for specifier in specifiers:
        by_suite.setdefault(specifier.split("/", 1)[0], []).append(specifier)
    selected_set = set(selected)
    selectors: list[str] = []
    for suite in sorted(by_suite):
        methods = by_suite[suite]
        chosen = [method for method in methods if method in selected_set]
        if not chosen:
            continue
        if len(chosen) == len(methods):
            selectors.append(suite)
        else:
            selectors.extend(chosen)
    return selectors


def direct_xctest_command(
    *,
    swift_binary: str,
    cwd: Path | None,
    test_filter: str | None,
    environment: Mapping[str, str],
    lister: BundleTestLister | None = None,
    bundle_discovery: Optional[Callable[[str, Path | None], Mapping[str, Path]]] = None,
    xctest_binary: Optional[Callable[[], tuple[str, ...]]] = None,
    scratch_path: Path | None = None,
) -> tuple[str, ...] | None:
    """Build the direct xctest invocation, or None when SwiftPM must run the tests.

    Running the built bundle directly avoids re-evaluating every package manifest under the
    sandboxed environment (the manifest cache is environment keyed) and the build re-plan that
    alternating `swift build` / `swift test` otherwise forces on the next job.
    """
    root = cwd or Path.cwd()
    if package_uses_swift_testing(root):
        return None
    if bundle_discovery is None:
        discovered = discover_test_bundles(swift_binary, cwd, scratch_path)
    else:
        discovered = bundle_discovery(swift_binary, cwd)
    bundle = package_test_bundle(discovered) if discovered else None
    if bundle is None:
        return None
    if lister is None:
        helper = xctest_helper_path(swift_binary)
        if helper is None:
            return None
        lister = helper_bundle_lister(helper)
    specifiers = lister(bundle, environment)
    if specifiers is None:
        return None
    selectors = select_xctest_specifiers(specifiers, test_filter)
    if selectors is None:
        return None
    if not selectors:
        return ()
    binary = (xctest_binary or xctest_binary_path)()
    return (*binary, "-XCTest", ",".join(selectors), str(bundle))


def run_local_tests(
    *,
    swift_binary: str,
    cwd: Path | None,
    test_filter: str | None = None,
    test_product: str | None = None,
    executor: CommandExecutor = execute_command,
    direct_command: Callable[..., tuple[str, ...] | None] = direct_xctest_command,
    scratch_path: Path | None = None,
    build_args: Sequence[str] = (),
) -> int:
    """Build the package tests, then run the selection in a sandbox.

    `scratch_path` and `build_args` exist for measurement builds (plan P0.5): extra compiler or
    linker flags go to a separate scratch path, so they never invalidate the shared `.build`.
    """
    if build_args and scratch_path is None:
        print("::error::extra build arguments require a separate scratch path")
        return 2
    swiftpm_args = (*scratch_path_args(scratch_path), *build_args)
    # Keep compilation and its caches outside the disposable runtime home.
    environment = dict(os.environ)
    status = executor((swift_binary, "build", "--build-tests", *swiftpm_args), cwd, environment)
    if status != 0:
        return status
    with tempfile.TemporaryDirectory(prefix="rpce-local-tests-") as directory:
        environment = isolated_suite_environment(Path(directory), "local", environment)
        command: tuple[str, ...] | None = None
        if test_product is None:
            command = direct_command(
                swift_binary=swift_binary, cwd=cwd, test_filter=test_filter, environment=environment,
                scratch_path=scratch_path,
            )
        if command == ():
            print("No matching test cases were run")
            return 1 if os.environ.get('CI') == 'true' and executor is execute_command else 0
        if command is None:
            command = (swift_binary, "test", "--skip-build", *swiftpm_args)
            if test_product:
                command += ("--test-product", test_product)
            if test_filter:
                command += ("--filter", test_filter)
        if os.environ.get('CI') == 'true' and executor is execute_command:
            if test_filter and not is_portable_filter(test_filter):
                print('::error::CI cannot prove this test filter matches SwiftPM semantics')
                return 2
            try:
                methods = list_suite_methods(swift_binary, cwd, skip_build=True)
                expected = listed_tests('\n'.join(method for tests in methods.values() for method in tests))
                if test_product:
                    # CI must not infer product membership from an aggregate listing.
                    print('::error::CI test-product execution requires its own authoritative listing')
                    return 2
                if test_filter:
                    expected = [method for method in expected if re.search(test_filter, method)]
                if not expected:
                    raise ValueError('CI filter selected zero tests')
                status, transcript = execute_logged(command, cwd, environment,
                                                    (cwd or Path.cwd()) / '.build/ci-test-results/local.log')
                verify_execution(expected, transcript, status)
                print(f'Filtered coverage: assigned={len(expected)}, executed={len(expected)}', flush=True)
                return 0
            except (ValueError, subprocess.CalledProcessError) as error:
                print(f'::error::CI local test execution: {error}')
                return 1
        return executor(command, cwd, environment)


MODULE_TEST_TARGET_PATTERN = re.compile(r"^[A-Za-z][A-Za-z0-9_]*Tests$")
MODULE_SCRATCH_PATH = Path(".build/swiftbuild")


def module_build_command(swift_binary: str, module: str) -> tuple[str, ...]:
    return (
        swift_binary, "build", "--build-system", "swiftbuild",
        "--scratch-path", str(MODULE_SCRATCH_PATH), "--product", module,
    )


def module_bundle_path(swift_binary: str, cwd: Path | None, module: str) -> Path | None:
    try:
        result = subprocess.run(
            [swift_binary, "build", "--build-system", "swiftbuild",
             "--scratch-path", str(MODULE_SCRATCH_PATH), "--show-bin-path"],
            check=True, capture_output=True, cwd=cwd, text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    bundle = Path(result.stdout.strip()) / f"{module}.xctest"
    if not bundle.is_absolute() and cwd is not None:
        bundle = cwd / bundle
    return bundle if bundle.is_dir() else None


def run_module_tests(
    *,
    swift_binary: str,
    cwd: Path | None,
    module: str,
    test_filter: str | None = None,
    executor: CommandExecutor = execute_command,
    bundle_locator: Callable[[str, Path | None, str], Path | None] = module_bundle_path,
    lister: BundleTestLister | None = None,
    xctest_binary: Optional[Callable[[], tuple[str, ...]]] = None,
    testing_helper: Optional[Callable[[str], Path | None]] = None,
    testing_environment: Optional[Callable[[Mapping[str, str]], dict[str, str] | None]] = None,
) -> int:
    """Build only one test target's dependency closure and run its bundle directly.

    Native SwiftPM links every test target into one aggregate bundle, so a focused run always
    builds and links the whole package. The Swift Build engine emits one bundle per test target,
    which keeps a module's test loop independent of unrelated targets (plan P0.3/P1.3).

    Like `swift test`, XCTest runs first, then Swift Testing when `Tests/<module>` imports it;
    both always run, and the run fails if either fails. Anything that could make selection
    differ from SwiftPM's fails closed instead of silently running fewer tests.
    """
    if not MODULE_TEST_TARGET_PATTERN.match(module):
        print(f"::error::--module must name a test target (got {module!r})")
        return 2
    test_sources = (cwd or Path.cwd()) / "Tests" / module
    if not test_sources.is_dir():
        print(f"::error::{test_sources} not found; cannot tell whether {module} uses Swift Testing")
        return 2
    testing_helper_binary: Path | None = None
    if sources_import_swift_testing(test_sources):
        testing_helper_binary = (testing_helper or swift_testing_helper_path)(swift_binary)
        if testing_helper_binary is None:
            print(f"::error::{module} imports Testing but swiftpm-testing-helper is unavailable")
            return 2
    if test_filter and not is_portable_filter(test_filter):
        print(f"::error::--filter {test_filter!r} uses regex syntax whose XCTest matching could differ "
              "from SwiftPM's; use a plain name or alternation, or run without --module")
        return 2
    environment = dict(os.environ)
    status = executor(module_build_command(swift_binary, module), cwd, environment)
    if status != 0:
        return status
    bundle = bundle_locator(swift_binary, cwd, module)
    if bundle is None:
        print(f"::error::built bundle for {module} was not found under {MODULE_SCRATCH_PATH}")
        return 2
    with tempfile.TemporaryDirectory(prefix="rpce-module-tests-") as directory:
        environment = isolated_suite_environment(Path(directory), module, environment)
        if lister is None:
            helper = xctest_helper_path(swift_binary)
            if helper is None:
                print("::error::swiftpm-xctest-helper is unavailable; cannot list module tests")
                return 2
            lister = helper_bundle_lister(helper)
        specifiers = lister(bundle, environment)
        if specifiers is None:
            print(f"::error::could not list tests in {bundle}")
            return 2
        selectors = select_xctest_specifiers(specifiers, test_filter)
        if selectors is None:
            print(f"::error::--filter could not be applied to XCTest: {test_filter!r}")
            return 2
        xctest_status = 0
        if selectors:
            binary = (xctest_binary or xctest_binary_path)()
            # As `swift test` does: otherwise xctest also hosts the Swift Testing tests, running them twice.
            xctest_environment = {**environment, "SWIFT_TESTING_ENABLED": "0"}
            command = (*binary, "-XCTest", ",".join(selectors), str(bundle))
            if os.environ.get('CI') == 'true' and executor is execute_command:
                expected = [s for s in specifiers if not test_filter or re.search(test_filter, s)]
                log_path = (cwd or Path.cwd()) / f'.build/ci-test-results/module-{module}.log'
                xctest_status, transcript = execute_logged(command, cwd, xctest_environment, log_path)
                try:
                    verify_execution(expected, transcript, xctest_status)
                except ValueError as error:
                    print(f'::error::{module}: {error}')
                    return xctest_status or 1
                print(f'Module coverage: {module} assigned={len(expected)}, executed={len(expected)}', flush=True)
            else:
                xctest_status = executor(command, cwd, xctest_environment)
        elif testing_helper_binary is None:
            print("No matching test cases were run")
            return 1 if os.environ.get('CI') == 'true' else 0
        if testing_helper_binary is None:
            return xctest_status
        testing_env = (testing_environment or developer_library_environment)(environment)
        if testing_env is None:
            print("::error::could not resolve the platform Developer frameworks for Swift Testing")
            return 2
        testing_status = executor(swift_testing_command(testing_helper_binary, bundle, test_filter), cwd, testing_env)
        if testing_status == SWIFT_TESTING_NO_TESTS_EXIT:
            testing_status = 0
        return xctest_status or testing_status


def execute_logged(command, cwd, environment, log_path: Path) -> tuple[int, str]:
    """Keep full output even on success; never infer execution from a conductor highlight."""
    log_path.parent.mkdir(parents=True, exist_ok=True)
    lines = []
    with log_path.open('a', encoding='utf-8') as log:
        log.write('$ ' + ' '.join(command) + '\n')
        try:
            process = subprocess.Popen(list(command), cwd=cwd, env=dict(environment),
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        except OSError as error:
            log.write(str(error) + '\n')
            return 127, str(error)
        assert process.stdout is not None
        for line in process.stdout:
            lines.append(line)
            log.write(line)
            log.flush()
            print(line, end='', flush=True)
        return process.wait(), ''.join(lines)


def run_selected_suites(
    suites: Sequence[str],
    *,
    swift_binary: str,
    cwd: Path | None,
    bundle_selection: BundleSelection,
    sandbox_root: Path,
    executor: CommandExecutor = execute_command,
    output: TextIO = sys.stdout,
    suite_methods: Mapping[str, Sequence[str]] | None = None,
    receipt_path: Path | None = None,
    shard_count: int = 1,
    shard_index: int = 1,
) -> int:
    executed = []
    skipped = []
    if suite_methods is not None and (not suites or receipt_path is None):
        print('::error::empty shard or missing receipt destination', file=output)
        return 2
    if receipt_path is not None:
        receipt_path.unlink(missing_ok=True)  # Never reuse a receipt from an interrupted attempt.
    for suite in suites:
        command = command_for_suite(
            suite,
            swift_binary=swift_binary,
            bundle_selection=bundle_selection,
        )
        environment = isolated_suite_environment(sandbox_root, suite)
        print(f"::group::{suite}", file=output, flush=True)
        print(f"sandbox={environment['REPOPROMPT_TEST_SANDBOX_ROOT']}", file=output)
        if suite_methods is None:
            return_code = executor(command, cwd, environment)
        else:
            environment['SWIFT_TESTING_ENABLED'] = '0'
            return_code, transcript = execute_logged(command, cwd, environment, receipt_path.with_suffix('.log'))
            try:
                result = verify_execution(list(suite_methods[suite]), transcript, return_code)
            except ValueError as error:
                print(f'::error::{suite}: {error}', file=output, flush=True)
                return return_code or 1
            executed.extend(result['executed'])
            skipped.extend(result['skipped'])
        print("::endgroup::", file=output, flush=True)

        if return_code == 0:
            continue
        print(
            f"::error::{suite} failed with exit status {return_code}",
            file=output,
            flush=True,
        )
        return return_code or 1
    if suite_methods is not None:
        full_listing = listed_tests('\n'.join(method for methods in suite_methods.values() for method in methods))
        assigned = sorted(method for suite in suites for method in suite_methods[suite])
        receipt = {'schema': 1, 'shard_index': shard_index, 'shard_count': shard_count,
                   'listing_sha256': listing_digest(full_listing), 'assigned': assigned,
                   'executed': sorted(executed), 'skipped': sorted(skipped)}
        receipt_path.write_text(json.dumps(receipt, sort_keys=True) + '\n')
        print(f'Coverage: assigned={len(assigned)}, executed={len(executed)}, skipped={len(skipped)}',
              file=output, flush=True)
    return 0


def print_selection_summary(
    *,
    selection: ShardSelection,
    suite_methods: Mapping[str, Sequence[str]],
    shard_count: int,
    shard_index: int,
    output: TextIO,
) -> None:
    method_count = sum(len(suite_methods[suite]) for suite in selection.suites)
    print(
        f"Selected test shard {shard_index}/{shard_count}: "
        f"{len(selection.suites)} suites, {method_count} methods; "
        f"all shard method loads={list(selection.method_loads)}",
        file=output,
    )


def verify_transferred_build(root: Path) -> str | None:
    """Fail closed before shard discovery when test products or gate attestations are missing."""
    try:
        validate_ci_artifact(root)
    except ValueError as error:
        return str(error)
    return None


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run deterministic RepoPrompt CE XCTest suites."
    )
    parser.add_argument("--local", action="store_true", help="Build, then run sandboxed local tests with SwiftPM selection")
    parser.add_argument("--skip-build", action="store_true", help="CI shard: discover and run transferred test bundles without compiling")
    parser.add_argument("--filter", dest="test_filter")
    parser.add_argument("--test-product")
    parser.add_argument("--module", help="Build and run only this test target (Swift Build engine)")
    parser.add_argument("--swift-binary", default="swift")
    parser.add_argument("--cwd", type=Path, default=None)
    parser.add_argument("--shard-count", type=int, default=1)
    parser.add_argument("--shard-index", type=int, default=1)
    parser.add_argument("--scratch-path", type=Path, help="Measurement builds: SwiftPM scratch path for --local")
    parser.add_argument(
        "--build-arg", dest="build_args", action="append", default=[],
        help="Measurement builds: extra SwiftPM build argument (use --build-arg=VALUE); requires --scratch-path",
    )
    args = parser.parse_args(argv)
    if args.local and args.skip_build:
        parser.error("--local cannot be combined with --skip-build")
    if args.local and (args.shard_count != 1 or args.shard_index != 1):
        parser.error("--local cannot be combined with sharding")
    if not args.local and (args.test_filter or args.test_product or args.module):
        parser.error("--filter, --test-product, and --module require --local")
    if args.module and args.test_product:
        parser.error("--module cannot be combined with --test-product")
    if (args.scratch_path or args.build_args) and (not args.local or args.module):
        parser.error("--scratch-path and --build-arg apply only to --local runs without --module")
    if args.build_args and not args.scratch_path:
        parser.error("--build-arg requires --scratch-path")
    return args


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    if args.local and args.module:
        return run_module_tests(
            swift_binary=args.swift_binary, cwd=args.cwd,
            module=args.module, test_filter=args.test_filter,
        )
    if args.local:
        return run_local_tests(
            swift_binary=args.swift_binary, cwd=args.cwd,
            test_filter=args.test_filter, test_product=args.test_product,
            scratch_path=args.scratch_path, build_args=tuple(args.build_args),
        )
    prebuilt_bin_path = None
    if args.skip_build:
        root = args.cwd or Path.cwd()
        try:
            prebuilt_bin_path = validate_ci_artifact(root)
        except ValueError as error:
            print(f"::error::{error}", file=sys.stderr)
            return 2
    try:
        validate_shard_args(args.shard_count, args.shard_index)
        if args.skip_build:
            listing = ((args.cwd or Path.cwd()) / '.build/modularization/ci-test-list.txt').read_text(encoding='utf-8')
            suite_methods = parse_suite_methods("\n".join(listed_tests(listing)))
        else:
            suite_methods = list_suite_methods(args.swift_binary, args.cwd)
    except ValueError as error:
        print(f"::error::{error}")
        return 2
    except subprocess.CalledProcessError as error:
        print(f"::error::swift test list failed with status {error.returncode}")
        if error.stdout:
            print(error.stdout, end="")
        if error.stderr:
            print(error.stderr, end="", file=sys.stderr)
        return error.returncode or 1

    selected_suites = tuple(sorted(suite_methods))
    method_counts = {
        suite: len(suite_methods[suite])
        for suite in selected_suites
    }
    try:
        selection = select_shard(
            method_counts,
            shard_count=args.shard_count,
            shard_index=args.shard_index,
        )
    except ValueError as error:
        print(f"::error::{error}")
        return 2

    print_selection_summary(
        selection=selection,
        suite_methods=suite_methods,
        shard_count=args.shard_count,
        shard_index=args.shard_index,
        output=sys.stdout,
    )
    if not selection.suites:
        print("::error::empty shard; refusing silent success")
        return 2

    try:
        bundle_selection = resolve_bundle_selection(
            swift_binary=args.swift_binary,
            cwd=args.cwd,
            suites=selection.suites,
            prebuilt_bin_path=prebuilt_bin_path,
        )
    except ValueError as error:
        print(f"::error::{error}")
        return 2

    with tempfile.TemporaryDirectory(prefix="rpce-tests-") as directory:
        return run_selected_suites(
            selection.suites,
            swift_binary=args.swift_binary,
            cwd=args.cwd,
            bundle_selection=bundle_selection,
            sandbox_root=Path(directory),
            suite_methods=suite_methods,
            receipt_path=(args.cwd or Path.cwd()) / f'.build/ci-test-results/shard-{args.shard_index}.json',
            shard_count=args.shard_count, shard_index=args.shard_index,
        )


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
