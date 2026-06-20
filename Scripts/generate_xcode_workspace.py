#!/usr/bin/env python3
"""Generate the disposable RepoPrompt CE developer workspace.

Package.swift remains the build graph.  This generator adds three legacy
convenience targets which delegate to the repository's existing developer
workflow, plus a native Swift package reference for the package graph and
source browsing.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape as xml_escape


SCHEMA_VERSION = 1
GENERATOR_ID = "com.repoprompt.ce.xcode-workspace-generator"
OWNERSHIP_MARKER = Path(".repoprompt-xcode-workspace")
WORKSPACE_NAME = "RepoPromptCE.xcworkspace"
PROJECT_NAME = "RepoPromptCE.xcodeproj"
APP_SCHEME = "RepoPrompt CE App"
MCP_SCHEME = "RepoPrompt CE MCP"
TEST_SCHEME = "RepoPrompt CE Tests"
REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_DESTINATION = REPO_ROOT / ".build/xcode"
CUSTOM_DESTINATION_ROOT = REPO_ROOT / ".build/xcode-custom"
DEFAULT_DEBUG_APP_BUNDLE = (
    Path.home() / "Library/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app"
)


class GeneratorError(RuntimeError):
    """A concise, user-actionable generation failure."""


def stable_id(label: str) -> str:
    return hashlib.sha256(label.encode("utf-8")).hexdigest()[:24].upper()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_package_manifest(repo_root: Path) -> dict:
    command = ["swift", "package", "dump-package"]
    try:
        result = subprocess.run(
            command,
            cwd=repo_root,
            check=False,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError as error:
        raise GeneratorError("swift is required; install/select the Xcode toolchain") from error
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "unknown error"
        raise GeneratorError(f"{' '.join(command)} failed: {detail}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise GeneratorError(f"swift package dump-package returned invalid JSON: {error}") from error


def _target_map(manifest: dict) -> dict[str, dict]:
    return {target.get("name", ""): target for target in manifest.get("targets", [])}


def validate_manifest(manifest: dict, repo_root: Path) -> None:
    if manifest.get("name") != "RepoPromptCE":
        raise GeneratorError("Package.swift must define package 'RepoPromptCE'")

    products = {product.get("name"): product for product in manifest.get("products", [])}
    for name in ("RepoPrompt", "repoprompt-mcp"):
        product = products.get(name)
        if product is None or "executable" not in product.get("type", {}):
            raise GeneratorError(f"Package.swift must retain executable product '{name}'")

    targets = _target_map(manifest)
    required_targets = (
        "RepoPrompt",
        "RepoPromptMCP",
        "RepoPromptShared",
        "RepoPromptC",
        "CSwiftPCRE2",
        "TreeSitterScannerSupport",
        "RepoPromptTests",
    )
    for name in required_targets:
        if name not in targets:
            raise GeneratorError(f"Package.swift must retain target '{name}'")

    unsafe_flags: list[list[str]] = []
    for setting in targets["RepoPrompt"].get("settings", []):
        value = setting.get("kind", {}).get("unsafeFlags", {}).get("_0")
        if isinstance(value, list):
            unsafe_flags.append(value)
    expected_header = repo_root / "Sources/RepoPrompt/Support/RepoPrompt-Bridging-Header.h"
    if not any(
        len(flags) == 3
        and flags[0] == "-import-objc-header"
        and Path(flags[1]) == expected_header
        and flags[2] == "-disable-bridging-pch"
        for flags in unsafe_flags
    ):
        raise GeneratorError(
            "RepoPrompt must retain the Objective-C bridging-header unsafe flags"
        )

    resources = [
        (resource.get("path"), "copy" in resource.get("rule", {}))
        for resource in targets["RepoPromptTests"].get("resources", [])
    ]
    expected_resources = [("CodeMap/Fixtures", True), ("CodeMap/Goldens", True)]
    if resources != expected_resources:
        raise GeneratorError(
            "RepoPromptTests must copy CodeMap/Fixtures and CodeMap/Goldens"
        )

    expected_scanners = ["src/javascript/scanner.c", "src/python/scanner.c"]
    scanners = targets["TreeSitterScannerSupport"].get("sources")
    if scanners != expected_scanners:
        raise GeneratorError(
            "TreeSitterScannerSupport must retain exactly the JavaScript and Python scanners"
        )

    required_paths = (
        "Package.swift",
        "Package.resolved",
        "Scripts/package_app.sh",
        "Scripts/xcode_developer_workflow.sh",
        "conductor",
        "AppBundle/Info.plist.template",
        "Vendor/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework",
    )
    for relative_path in required_paths:
        if not (repo_root / relative_path).exists():
            raise GeneratorError(f"required repository path is missing: {relative_path}")


def render_workspace(repository_relative_path: str) -> str:
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<Workspace
   version = "1.0">
   <FileRef
      location = "group:RepoPromptCE.xcodeproj">
   </FileRef>
   <FileRef
      location = "group:{repository_relative_path}">
   </FileRef>
</Workspace>
"""


def render_project(repository_relative_path: str) -> str:
    project_id = stable_id("project")
    main_group_id = stable_id("group:main")
    products_group_id = stable_id("group:products")
    repository_group_id = stable_id("group:repository")
    app_target_id = stable_id("target:app")
    mcp_target_id = stable_id("target:mcp")
    test_target_id = stable_id("target:test")
    project_config_list_id = stable_id("config-list:project")
    app_config_list_id = stable_id("config-list:app")
    mcp_config_list_id = stable_id("config-list:mcp")
    test_config_list_id = stable_id("config-list:test")
    project_debug_id = stable_id("config:project:debug")
    project_release_id = stable_id("config:project:release")
    app_debug_id = stable_id("config:app:debug")
    app_release_id = stable_id("config:app:release")
    mcp_debug_id = stable_id("config:mcp:debug")
    mcp_release_id = stable_id("config:mcp:release")
    test_debug_id = stable_id("config:test:debug")
    test_release_id = stable_id("config:test:release")

    folder_names = ("Sources", "Tests", "Packages", "AppBundle", "AppResources", "Scripts", "docs")
    folder_ids = {name: stable_id(f"folder:{name}") for name in folder_names}
    root_files = (
        ("Package.swift", "sourcecode.swift"),
        ("Package.resolved", "text.json"),
        ("Makefile", "text.script.sh"),
        ("README.md", "net.daringfireball.markdown"),
        ("CONTRIBUTING.md", "net.daringfireball.markdown"),
        ("AGENTS.md", "net.daringfireball.markdown"),
    )
    file_ids = {name: stable_id(f"file:{name}") for name, _ in root_files}

    folder_section = "\n".join(
        f"\t\t{folder_ids[name]} /* {name} */ = {{isa = PBXFileSystemSynchronizedRootGroup; path = {repository_relative_path}/{name}; sourceTree = \"<group>\"; }};"
        for name in folder_names
    )
    file_section = "\n".join(
        f"\t\t{file_ids[name]} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {file_type}; path = {repository_relative_path}/{name}; sourceTree = \"<group>\"; }};"
        for name, file_type in root_files
    )
    main_children = "\n".join(
        [f"\t\t\t\t{folder_ids[name]} /* {name} */," for name in folder_names]
        + [f"\t\t\t\t{repository_group_id} /* Repository Files */,"]
        + [f"\t\t\t\t{products_group_id} /* Products */,"]
    )
    repo_children = "\n".join(
        f"\t\t\t\t{file_ids[name]} /* {name} */," for name, _ in root_files
    )

    return f"""// !$*UTF8*$!
{{
\tarchiveVersion = 1;
\tclasses = {{
\t}};
\tobjectVersion = 77;
\tobjects = {{

/* Begin PBXFileReference section */
{file_section}
/* End PBXFileReference section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
{folder_section}
/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXGroup section */
\t\t{main_group_id} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{main_children}
\t\t\t);
\t\t\tsourceTree = \"<group>\";
\t\t}};
\t\t{products_group_id} /* Products */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t);
\t\t\tname = Products;
\t\t\tsourceTree = \"<group>\";
\t\t}};
\t\t{repository_group_id} /* Repository Files */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{repo_children}
\t\t\t);
\t\t\tname = \"Repository Files\";
\t\t\tsourceTree = \"<group>\";
\t\t}};
/* End PBXGroup section */

/* Begin PBXLegacyTarget section */
\t\t{app_target_id} /* {APP_SCHEME} */ = {{
\t\t\tisa = PBXLegacyTarget;
\t\t\tbuildArgumentsString = app;
\t\t\tbuildConfigurationList = {app_config_list_id} /* Build configuration list for PBXLegacyTarget \"{APP_SCHEME}\" */;
\t\t\tbuildPhases = (
\t\t\t);
\t\t\tbuildToolPath = \"$(SRCROOT)/{repository_relative_path}/Scripts/xcode_developer_workflow.sh\";
\t\t\tbuildWorkingDirectory = \"$(SRCROOT)/{repository_relative_path}\";
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = \"{APP_SCHEME}\";
\t\t\tpassBuildSettingsInEnvironment = 0;
\t\t\tproductName = \"{APP_SCHEME}\";
\t\t}};
\t\t{mcp_target_id} /* {MCP_SCHEME} */ = {{
\t\t\tisa = PBXLegacyTarget;
\t\t\tbuildArgumentsString = mcp;
\t\t\tbuildConfigurationList = {mcp_config_list_id} /* Build configuration list for PBXLegacyTarget \"{MCP_SCHEME}\" */;
\t\t\tbuildPhases = (
\t\t\t);
\t\t\tbuildToolPath = \"$(SRCROOT)/{repository_relative_path}/Scripts/xcode_developer_workflow.sh\";
\t\t\tbuildWorkingDirectory = \"$(SRCROOT)/{repository_relative_path}\";
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = \"{MCP_SCHEME}\";
\t\t\tpassBuildSettingsInEnvironment = 0;
\t\t\tproductName = \"{MCP_SCHEME}\";
\t\t}};
\t\t{test_target_id} /* {TEST_SCHEME} */ = {{
\t\t\tisa = PBXLegacyTarget;
\t\t\tbuildArgumentsString = test;
\t\t\tbuildConfigurationList = {test_config_list_id} /* Build configuration list for PBXLegacyTarget \"{TEST_SCHEME}\" */;
\t\t\tbuildPhases = (
\t\t\t);
\t\t\tbuildToolPath = \"$(SRCROOT)/{repository_relative_path}/Scripts/xcode_developer_workflow.sh\";
\t\t\tbuildWorkingDirectory = \"$(SRCROOT)/{repository_relative_path}\";
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = \"{TEST_SCHEME}\";
\t\t\tpassBuildSettingsInEnvironment = 0;
\t\t\tproductName = \"{TEST_SCHEME}\";
\t\t}};
/* End PBXLegacyTarget section */

/* Begin PBXProject section */
\t\t{project_id} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastUpgradeCheck = 2630;
\t\t\t}};
\t\t\tbuildConfigurationList = {project_config_list_id} /* Build configuration list for PBXProject \"RepoPromptCE\" */;
\t\t\tcompatibilityVersion = \"Xcode 16.0\";
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {main_group_id};
\t\t\tminimizedProjectReferenceProxies = 1;
\t\t\tpreferredProjectObjectVersion = 77;
\t\t\tproductRefGroup = {products_group_id} /* Products */;
\t\t\tprojectDirPath = \"\";
\t\t\tprojectRoot = \"\";
\t\t\ttargets = (
\t\t\t\t{app_target_id} /* {APP_SCHEME} */,
\t\t\t\t{mcp_target_id} /* {MCP_SCHEME} */,
\t\t\t\t{test_target_id} /* {TEST_SCHEME} */,
\t\t\t);
\t\t}};
/* End PBXProject section */

/* Begin XCBuildConfiguration section */
\t\t{project_debug_id} /* Debug */ = {{isa = XCBuildConfiguration; buildSettings = {{}}; name = Debug; }};
\t\t{project_release_id} /* Release */ = {{isa = XCBuildConfiguration; buildSettings = {{}}; name = Release; }};
\t\t{app_debug_id} /* Debug */ = {{isa = XCBuildConfiguration; buildSettings = {{PRODUCT_NAME = \"{APP_SCHEME}\"; }}; name = Debug; }};
\t\t{app_release_id} /* Release */ = {{isa = XCBuildConfiguration; buildSettings = {{PRODUCT_NAME = \"{APP_SCHEME}\"; }}; name = Release; }};
\t\t{mcp_debug_id} /* Debug */ = {{isa = XCBuildConfiguration; buildSettings = {{PRODUCT_NAME = \"{MCP_SCHEME}\"; }}; name = Debug; }};
\t\t{mcp_release_id} /* Release */ = {{isa = XCBuildConfiguration; buildSettings = {{PRODUCT_NAME = \"{MCP_SCHEME}\"; }}; name = Release; }};
\t\t{test_debug_id} /* Debug */ = {{isa = XCBuildConfiguration; buildSettings = {{PRODUCT_NAME = \"{TEST_SCHEME}\"; }}; name = Debug; }};
\t\t{test_release_id} /* Release */ = {{isa = XCBuildConfiguration; buildSettings = {{PRODUCT_NAME = \"{TEST_SCHEME}\"; }}; name = Release; }};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
\t\t{project_config_list_id} /* Build configuration list for PBXProject \"RepoPromptCE\" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = ({project_debug_id} /* Debug */, {project_release_id} /* Release */);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Debug;
\t\t}};
\t\t{app_config_list_id} /* Build configuration list for PBXLegacyTarget \"{APP_SCHEME}\" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = ({app_debug_id} /* Debug */, {app_release_id} /* Release */);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Debug;
\t\t}};
\t\t{mcp_config_list_id} /* Build configuration list for PBXLegacyTarget \"{MCP_SCHEME}\" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = ({mcp_debug_id} /* Debug */, {mcp_release_id} /* Release */);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Debug;
\t\t}};
\t\t{test_config_list_id} /* Build configuration list for PBXLegacyTarget \"{TEST_SCHEME}\" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = ({test_debug_id} /* Debug */, {test_release_id} /* Release */);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Debug;
\t\t}};
/* End XCConfigurationList section */
\t}};
\trootObject = {project_id} /* Project object */;
}}
"""


def render_scheme(
    name: str,
    target_label: str,
    runnable_path: str,
    app: bool,
    repository_relative_path: str,
    working_directory: Path,
) -> str:
    target_id = stable_id(target_label)
    repository_path = f"$(PROJECT_DIR)/{repository_relative_path}"
    escaped_runnable_path = xml_escape(runnable_path)
    escaped_working_directory = xml_escape(str(working_directory))
    environment = ""
    preactions = ""
    if app:
        environment = f"""
      <EnvironmentVariables>
         <EnvironmentVariable key = "REPOPROMPT_LAUNCH_SOURCE" value = "xcode" isEnabled = "YES"/>
         <EnvironmentVariable key = "__XCODE_BUILT_PRODUCTS_DIR_PATHS" value = "{repository_path}/.build/debug" isEnabled = "YES"/>
      </EnvironmentVariables>"""
        preactions = f"""
      <PreActions>
         <ExecutionAction ActionType = "Xcode.IDEStandardExecutionActionsCore.ExecutionActionType.ShellScriptAction">
            <ActionContent title = "Stop existing RepoPrompt CE debug app" scriptText = "&quot;${{PROJECT_DIR}}/{repository_relative_path}/Scripts/xcode_developer_workflow.sh&quot; prepare-app-run">
               <EnvironmentBuildable>
                  <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{target_id}" BuildableName = "{name}" BlueprintName = "{name}" ReferencedContainer = "container:{PROJECT_NAME}"/>
               </EnvironmentBuildable>
            </ActionContent>
         </ExecutionAction>
      </PreActions>"""

    buildable = f'<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{target_id}" BuildableName = "{name}" BlueprintName = "{name}" ReferencedContainer = "container:{PROJECT_NAME}"/>'
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2630" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "NO" buildForRunning = "YES" buildForProfiling = "NO" buildForArchiving = "NO" buildForAnalyzing = "YES">
            {buildable}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables/>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "YES" customWorkingDirectory = "{escaped_working_directory}" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">{preactions}
      <PathRunnable runnableDebuggingMode = "0" FilePath = "{escaped_runnable_path}"/>{environment}
   </LaunchAction>
   <ProfileAction buildConfiguration = "Debug" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "YES" customWorkingDirectory = "{escaped_working_directory}" debugDocumentVersioning = "YES">
      <PathRunnable runnableDebuggingMode = "0" FilePath = "{escaped_runnable_path}"/>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug"/>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "NO"/>
</Scheme>
"""


def render_test_scheme(working_directory: Path) -> str:
    target_id = stable_id("target:test")
    escaped_working_directory = xml_escape(str(working_directory))
    buildable = (
        f'<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{target_id}" '
        f'BuildableName = "{TEST_SCHEME}" BlueprintName = "{TEST_SCHEME}" '
        f'ReferencedContainer = "container:{PROJECT_NAME}"/>'
    )
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2630" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "NO" buildForArchiving = "NO" buildForAnalyzing = "YES">
            {buildable}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables/>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "YES" customWorkingDirectory = "{escaped_working_directory}" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <PathRunnable runnableDebuggingMode = "0" FilePath = "/usr/bin/true"/>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Debug" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES"/>
   <AnalyzeAction buildConfiguration = "Debug"/>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "NO"/>
</Scheme>
"""


def render_generated_readme() -> str:
    return """# Generated RepoPrompt CE Xcode Workspace

This directory is disposable. Regenerate it with `make xcode-generate`; do not edit it.

- `RepoPrompt CE App` builds and runs the canonical packaged debug app through conductor.
- `RepoPrompt CE MCP` builds the MCP executable through conductor.
- `RepoPrompt CE Tests` builds the authoritative XCTest suite through conductor. Set
  `REPOPROMPT_XCODE_TEST_FILTER` before building to run a focused filter.

The root Swift package reference provides source browsing and indexing. Its native Xcode
test action is not the supported test workflow because Xcode does not expose the
`RepoPromptMCP` executable dependency as an importable test module. The vendored Sparkle
XCFramework also declares an omitted dSYMs directory; this generator deliberately does
not mutate `Vendor/` to compensate. Use the convenience schemes above.

Xcode does not expand project macros reliably for every external runnable field. The
generated app scheme records the current worktree root as the working directory and the
local debug app bundle path as the Run/Profile runnable. Regenerate after moving the
checkout or changing the local debug app bundle location; build-time repository
references remain relative.
"""


def repository_relative_path(repo_root: Path, destination: Path) -> str:
    return Path(os.path.relpath(repo_root, destination)).as_posix()


def render_generation_manifest(
    repo_root: Path,
    manifest: dict,
    repository_relative_path: str,
) -> str:
    targets = sorted(_target_map(manifest))
    products = sorted(product["name"] for product in manifest.get("products", []))
    payload = {
        "generator": GENERATOR_ID,
        "inputs": {
            "Package.resolved": sha256_file(repo_root / "Package.resolved"),
            "Package.swift": sha256_file(repo_root / "Package.swift"),
            "Scripts/generate_xcode_workspace.py": sha256_file(Path(__file__).resolve()),
            "Scripts/xcode_developer_workflow.sh": sha256_file(
                repo_root / "Scripts/xcode_developer_workflow.sh"
            ),
        },
        "package": {"name": manifest["name"], "products": products, "targets": targets},
        "repositoryRelativePath": repository_relative_path,
        "schemaVersion": SCHEMA_VERSION,
    }
    return json.dumps(payload, indent=2, sort_keys=True) + "\n"


def render_outputs(
    repo_root: Path,
    manifest: dict,
    destination: Path = DEFAULT_DESTINATION,
) -> dict[Path, bytes]:
    validate_manifest(manifest, repo_root)
    relative_repo = repository_relative_path(repo_root, destination)
    return {
        Path(WORKSPACE_NAME) / "contents.xcworkspacedata": render_workspace(relative_repo).encode(),
        Path(WORKSPACE_NAME) / "xcshareddata/swiftpm/Package.resolved": (
            repo_root / "Package.resolved"
        ).read_bytes(),
        Path(PROJECT_NAME) / f"xcshareddata/xcschemes/{TEST_SCHEME}.xcscheme": (
            render_test_scheme(repo_root).encode()
        ),
        Path(PROJECT_NAME) / "project.pbxproj": render_project(relative_repo).encode(),
        Path(PROJECT_NAME) / f"xcshareddata/xcschemes/{APP_SCHEME}.xcscheme": render_scheme(
            APP_SCHEME,
            "target:app",
            str(DEFAULT_DEBUG_APP_BUNDLE),
            app=True,
            repository_relative_path=relative_repo,
            working_directory=repo_root,
        ).encode(),
        Path(PROJECT_NAME) / f"xcshareddata/xcschemes/{MCP_SCHEME}.xcscheme": render_scheme(
            MCP_SCHEME,
            "target:mcp",
            f"$(PROJECT_DIR)/{relative_repo}/.build/debug/repoprompt-mcp",
            app=False,
            repository_relative_path=relative_repo,
            working_directory=repo_root,
        ).encode(),
        Path("README.md"): render_generated_readme().encode(),
        OWNERSHIP_MARKER: f"{GENERATOR_ID}\n".encode(),
        Path("generation.json"): render_generation_manifest(
            repo_root,
            manifest,
            relative_repo,
        ).encode(),
    }


def metadata_from_outputs(outputs: dict[Path, bytes]) -> dict:
    try:
        return json.loads(outputs[Path("generation.json")])
    except (KeyError, json.JSONDecodeError) as error:
        raise GeneratorError(f"rendered generation metadata is invalid: {error}") from error


def expected_symlinks(outputs: dict[Path, bytes]) -> dict[Path, str]:
    metadata = metadata_from_outputs(outputs)
    relative_repo = metadata.get("repositoryRelativePath")
    if not isinstance(relative_repo, str) or not relative_repo:
        raise GeneratorError("rendered generation metadata lacks repositoryRelativePath")
    return {Path("Sources"): f"{relative_repo}/Sources"}


def _write_tree(destination: Path, outputs: dict[Path, bytes]) -> None:
    for relative_path, content in sorted(outputs.items(), key=lambda item: str(item[0])):
        path = destination / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
    for relative_path, target in sorted(expected_symlinks(outputs).items(), key=lambda item: str(item[0])):
        path = destination / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.symlink_to(target, target_is_directory=True)


def validate_structure(destination: Path) -> None:
    marker = destination / OWNERSHIP_MARKER
    try:
        marker_content = marker.read_text()
    except OSError as error:
        raise GeneratorError(f"generated ownership marker is missing: {error}") from error
    if marker.is_symlink() or marker_content != f"{GENERATOR_ID}\n":
        raise GeneratorError("generated ownership marker is invalid")

    try:
        generation = json.loads((destination / "generation.json").read_text())
    except (json.JSONDecodeError, OSError) as error:
        raise GeneratorError(f"invalid generation.json: {error}") from error
    if generation.get("generator") != GENERATOR_ID:
        raise GeneratorError("generation.json does not identify this generator")
    if generation.get("schemaVersion") != SCHEMA_VERSION:
        raise GeneratorError("generation.json schema version is stale")
    relative_repo = generation.get("repositoryRelativePath")
    if not isinstance(relative_repo, str) or not relative_repo:
        raise GeneratorError("generation.json lacks repositoryRelativePath")

    workspace_path = destination / WORKSPACE_NAME / "contents.xcworkspacedata"
    try:
        workspace = ET.parse(workspace_path)
    except (ET.ParseError, OSError) as error:
        raise GeneratorError(f"invalid generated workspace XML: {error}") from error
    locations = {node.attrib.get("location") for node in workspace.findall(".//FileRef")}
    if locations != {"group:RepoPromptCE.xcodeproj", f"group:{relative_repo}"}:
        raise GeneratorError("generated workspace does not reference the project and root package")

    project_text = (destination / PROJECT_NAME / "project.pbxproj").read_text()
    if project_text.count("isa = PBXLegacyTarget;") != 3:
        raise GeneratorError("generated project must contain exactly three convenience targets")
    for name in (APP_SCHEME, MCP_SCHEME, TEST_SCHEME):
        if name not in project_text:
            raise GeneratorError(f"generated project is missing target '{name}'")

    for name in (APP_SCHEME, MCP_SCHEME):
        scheme_path = destination / PROJECT_NAME / f"xcshareddata/xcschemes/{name}.xcscheme"
        try:
            ET.parse(scheme_path)
        except (ET.ParseError, OSError) as error:
            raise GeneratorError(f"invalid generated scheme XML for '{name}': {error}") from error

    test_scheme_path = destination / PROJECT_NAME / f"xcshareddata/xcschemes/{TEST_SCHEME}.xcscheme"
    try:
        test_scheme = ET.parse(test_scheme_path)
    except (ET.ParseError, OSError) as error:
        raise GeneratorError(f"invalid generated scheme XML for '{TEST_SCHEME}': {error}") from error
    test_blueprints = {
        node.attrib.get("BlueprintName")
        for node in test_scheme.findall(".//BuildableReference")
    }
    if TEST_SCHEME not in test_blueprints:
        raise GeneratorError("generated test scheme does not reference the test workflow target")

    for relative_path, target in {Path("Sources"): f"{relative_repo}/Sources"}.items():
        path = destination / relative_path
        if not path.is_symlink() or os.readlink(path) != target:
            raise GeneratorError(f"generated compatibility symlink is stale: {relative_path}")

def lexical_absolute(path: Path) -> Path:
    return Path(os.path.abspath(os.fspath(path.expanduser())))


def reject_symlinked_components(path: Path, repository_root: Path) -> None:
    repository_root = lexical_absolute(repository_root)
    path = lexical_absolute(path)
    try:
        relative = path.relative_to(repository_root)
    except ValueError as error:
        raise GeneratorError(f"destination must remain inside {repository_root}") from error
    current = repository_root
    if current.is_symlink():
        raise GeneratorError(f"symlinked destination component is not allowed: {current}")
    for component in relative.parts:
        current /= component
        if current.is_symlink():
            raise GeneratorError(f"symlinked destination component is not allowed: {current}")
        if current.exists() and current != path and not current.is_dir():
            raise GeneratorError(f"destination parent is not a directory: {current}")


def validate_destination(
    destination: Path,
    default_destination: Path = DEFAULT_DESTINATION,
    custom_root: Path = CUSTOM_DESTINATION_ROOT,
    repository_root: Path = REPO_ROOT,
) -> Path:
    destination = lexical_absolute(destination)
    default_destination = lexical_absolute(default_destination)
    custom_root = lexical_absolute(custom_root)
    if destination != default_destination and (
        destination == custom_root or not destination.is_relative_to(custom_root)
    ):
        raise GeneratorError(
            "destination must be the default .build/xcode path or a child of the "
            f"dedicated custom-output root: {custom_root}"
        )
    reject_symlinked_components(destination, repository_root)
    return destination


def validate_generator_owned_destination(destination: Path) -> None:
    if not destination.exists():
        return
    if not destination.is_dir():
        raise GeneratorError(f"existing destination is not a directory: {destination}")
    marker = destination / OWNERSHIP_MARKER
    if marker.is_symlink() or not marker.is_file():
        raise GeneratorError(
            f"refusing to replace non-generator-owned destination: {destination}; "
            "remove it manually or choose another destination"
        )
    try:
        marker_content = marker.read_text()
    except OSError as error:
        raise GeneratorError(
            f"refusing to replace destination with an invalid ownership marker: {destination}"
        ) from error
    if marker_content != f"{GENERATOR_ID}\n":
        raise GeneratorError(
            f"refusing to replace destination owned by another tool: {destination}"
        )


@contextmanager
def generation_lock(destination: Path):
    destination.parent.mkdir(parents=True, exist_ok=True)
    lock_path = destination.parent / f".{destination.name}.generation.lock"
    with lock_path.open("a+b") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


def atomic_exchange_directories(left: Path, right: Path) -> None:
    if sys.platform != "darwin":
        raise GeneratorError("atomic workspace regeneration requires macOS")
    libc = ctypes.CDLL(None, use_errno=True)
    renameatx_np = libc.renameatx_np
    renameatx_np.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    renameatx_np.restype = ctypes.c_int
    at_fdcwd = -2
    rename_swap = 0x00000002
    result = renameatx_np(
        at_fdcwd,
        os.fsencode(left),
        at_fdcwd,
        os.fsencode(right),
        rename_swap,
    )
    if result != 0:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number))


def write_outputs(
    destination: Path,
    outputs: dict[Path, bytes],
    *,
    default_destination: Path = DEFAULT_DESTINATION,
    custom_root: Path = CUSTOM_DESTINATION_ROOT,
    repository_root: Path = REPO_ROOT,
) -> None:
    destination = validate_destination(
        destination,
        default_destination,
        custom_root,
        repository_root,
    )
    with generation_lock(destination):
        destination = validate_destination(
            destination,
            default_destination,
            custom_root,
            repository_root,
        )
        validate_generator_owned_destination(destination)
        stage = Path(tempfile.mkdtemp(prefix=f".{destination.name}.tmp-", dir=destination.parent))
        try:
            _write_tree(stage, outputs)
            validate_structure(stage)
            if destination.exists():
                atomic_exchange_directories(stage, destination)
                shutil.rmtree(stage)
            else:
                os.replace(stage, destination)
        finally:
            if stage.exists():
                shutil.rmtree(stage)


def is_ignored_xcode_user_path(relative_path: Path) -> bool:
    if not relative_path.parts or relative_path.parts[0] not in {WORKSPACE_NAME, PROJECT_NAME}:
        return False
    return (
        "xcuserdata" in relative_path.parts
        or any(part.endswith(".xcuserdatad") for part in relative_path.parts)
        or relative_path.name.endswith(".xcuserstate")
    )


def check_outputs(destination: Path, outputs: dict[Path, bytes]) -> None:
    with generation_lock(destination):
        if not destination.is_dir():
            raise GeneratorError(f"generated workspace is missing at {destination}; run xcode-generate")
        actual_files = {
            path.relative_to(destination)
            for path in destination.rglob("*")
            if path.is_file()
            and not is_ignored_xcode_user_path(path.relative_to(destination))
        }
        expected_files = set(outputs)
        missing = sorted(expected_files - actual_files, key=str)
        if missing:
            raise GeneratorError(f"generated file is missing: {missing[0]}; run xcode-generate")
        unexpected = sorted(actual_files - expected_files, key=str)
        if unexpected:
            raise GeneratorError(f"unexpected generated file: {unexpected[0]}; run xcode-generate")
        for relative_path in sorted(expected_files, key=str):
            if (destination / relative_path).read_bytes() != outputs[relative_path]:
                raise GeneratorError(f"generated file is stale: {relative_path}; run xcode-generate")
        for relative_path, target in expected_symlinks(outputs).items():
            path = destination / relative_path
            if not path.is_symlink() or os.readlink(path) != target:
                raise GeneratorError(f"generated compatibility symlink is stale: {relative_path}; run xcode-generate")
        validate_structure(destination)


def validate_xcodebuild_list(destination: Path) -> None:
    workspace = destination / WORKSPACE_NAME
    command = ["xcodebuild", "-list", "-json", "-workspace", str(workspace)]
    try:
        result = subprocess.run(command, check=False, capture_output=True, text=True)
    except FileNotFoundError as error:
        raise GeneratorError("xcodebuild is required; install/select Xcode") from error
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "unknown error"
        raise GeneratorError(f"xcodebuild -list failed: {detail}")
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise GeneratorError(f"xcodebuild -list returned invalid JSON: {error}") from error
    schemes = set(payload.get("workspace", {}).get("schemes", []))
    required = {APP_SCHEME, MCP_SCHEME, TEST_SCHEME, "RepoPrompt"}
    missing = sorted(required - schemes)
    if missing:
        available = ", ".join(sorted(schemes)) or "none"
        raise GeneratorError(
            f"xcodebuild did not discover scheme '{missing[0]}' (available: {available})"
        )


def destination_from_argument(value: str) -> Path:
    path = Path(value).expanduser()
    if not path.is_absolute():
        path = REPO_ROOT / path
    return validate_destination(path)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("generate", "check", "validate", "print-path"):
        subparser = subparsers.add_parser(command)
        subparser.add_argument("--destination", default=".build/xcode")
        if command == "validate":
            subparser.add_argument("--xcodebuild-list", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    destination = destination_from_argument(args.destination)
    if args.command == "print-path":
        print(destination / WORKSPACE_NAME)
        return 0

    manifest = load_package_manifest(REPO_ROOT)
    outputs = render_outputs(REPO_ROOT, manifest, destination)
    if args.command == "generate":
        write_outputs(destination, outputs)
        print(f"Generated {destination / WORKSPACE_NAME}")
    elif args.command == "check":
        check_outputs(destination, outputs)
        print(f"Generated workspace is current: {destination / WORKSPACE_NAME}")
    elif args.command == "validate":
        check_outputs(destination, outputs)
        if args.xcodebuild_list:
            validate_xcodebuild_list(destination)
        print(f"Validated {destination / WORKSPACE_NAME}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except GeneratorError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
