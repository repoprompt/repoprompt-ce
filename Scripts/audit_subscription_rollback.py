#!/usr/bin/env python3
"""Read-only precheck of a quiesced, isolated pre-activation RepoPrompt snapshot."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import stat
from urllib.parse import unquote, urlsplit
from uuid import UUID
from xml.parsers.expat import ExpatError


class AuditFailure(ValueError):
    """Safe diagnostic code; never include settings, transcript content, or paths."""


def regular(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise AuditFailure("unsafe_snapshot_file")
    return path


def paths(root):
    """Enumerate an app-owned tree without following links or opening arbitrary files."""
    if not stat.S_ISDIR(root.lstat().st_mode):
        raise AuditFailure("unsafe_snapshot_directory")
    for parent, dirs, files in os.walk(root, followlinks=False, onerror=_raise):
        for name in dirs:
            child = Path(parent) / name
            if not stat.S_ISDIR(child.lstat().st_mode):
                raise AuditFailure("unsafe_snapshot_directory")
            if name == "ManagedSubscriptionProfiles":
                raise AuditFailure("managed_profile_store_present")
        for name in files:
            yield regular(Path(parent) / name)


def _raise(error):
    raise error


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise AuditFailure("duplicate_snapshot_key")
        result[key] = value
    return result


def read_json(path):
    return json.loads(regular(path).read_bytes(), object_pairs_hook=unique_object)


def read_object(path):
    obj = read_json(path)
    if not isinstance(obj, dict):
        raise AuditFailure("invalid_snapshot_document")
    return obj


def rows(value):
    if not isinstance(value, list) or any(not isinstance(row, dict) for row in value):
        raise AuditFailure("invalid_workspace_inventory")
    return value


def workspace_id(value):
    if not isinstance(value, str):
        raise AuditFailure("invalid_workspace_identity")
    try:
        identity = UUID(value)
        if str(identity) != value.lower():
            raise ValueError("noncanonical UUID")
        return identity
    except ValueError as error:
        raise AuditFailure("invalid_workspace_identity") from error


def require_no_custom_storage(document):
    if document.get("customStoragePath") is not None:
        raise AuditFailure("custom_storage_not_rehomed")


def file_url(value):
    if not isinstance(value, str):
        raise AuditFailure("invalid_workspace_catalog_location")
    url = urlsplit(value)
    if url.scheme != "file" or url.netloc not in ("", "localhost") or url.query or url.fragment:
        raise AuditFailure("invalid_workspace_catalog_location")
    path = Path(unquote(url.path, errors="strict"))
    if not path.is_absolute() or ".." in path.parts:
        raise AuditFailure("invalid_workspace_catalog_location")
    return path


def audit(snapshot, preferences, retained_roots, max_settings_schema):
    root = snapshot.absolute()
    if root.resolve(strict=True) != root or not root.is_dir() or not retained_roots:
        raise AuditFailure("invalid_snapshot_root")
    if (root / "ManagedSubscriptionProfiles").exists() or (root / "ManagedSubscriptionProfiles").is_symlink():
        raise AuditFailure("managed_profile_store_present")
    for path in retained_roots:
        retained = path.resolve(strict=True)
        if not retained.is_dir() or root.is_relative_to(retained) or retained.is_relative_to(root):
            raise AuditFailure("snapshot_overlaps_retained_storage")

    # Inputs name the staged preference export, never the live preferences domain.
    pref = preferences.absolute()
    if not pref.is_relative_to(root) or pref.parent.resolve(strict=True) != pref.parent:
        raise AuditFailure("preference_export_outside_snapshot")
    flags = plistlib.loads(regular(pref).read_bytes())
    if not isinstance(flags, dict):
        raise AuditFailure("invalid_preference_export")
    if "GlobalCustomStorageURL" in flags:
        raise AuditFailure("global_custom_storage_override")

    settings_root = root / "Settings"
    if not stat.S_ISDIR(settings_root.lstat().st_mode):
        raise AuditFailure("unsafe_snapshot_directory")
    settings = read_object(settings_root / "globalSettings.json")
    version = settings.get("schemaVersion")
    lineage = settings.get("schemaLineage")
    if type(version) is not int or not 1 <= version <= max_settings_schema or version == 6:
        raise AuditFailure("settings_schema_unsupported")
    if lineage != "repoprompt-ce.global-settings" and not (lineage is None and version <= 2):
        raise AuditFailure("settings_schema_unsupported")
    scalar = settings.get("scalarPreferences")
    if scalar is None:
        scalar = {}
    if not isinstance(scalar, dict) or "subscriptionProfileCatalog" in scalar:
        raise AuditFailure("managed_catalog_present")

    workspaces = root / "Workspaces"
    workspace_documents = {}
    session_count = 0
    for path in paths(workspaces):
        if path.name == "workspace.json":
            workspace = read_object(path)
            require_no_custom_storage(workspace)
            identity = workspace_id(workspace.get("id"))
            if identity in workspace_documents:
                raise AuditFailure("duplicate_workspace_identity")
            workspace_documents[identity] = path
        elif path.name.startswith("AgentSession-") and path.suffix == ".json":
            if "subscriptionAccountBinding" in read_object(path):
                raise AuditFailure("managed_session_present")
            session_count += 1

    for row in rows(read_json(workspaces / "workspacesIndex.json")):
        require_no_custom_storage(row)
        if workspace_id(row.get("id")) not in workspace_documents:
            raise AuditFailure("workspace_document_missing")

    runtime = root / "DomainRuntime"
    if runtime.exists() or runtime.is_symlink():
        for path in paths(runtime):
            if path.name == "workspace-catalog.json":
                catalog = read_object(path)
                if type(catalog.get("version")) is not int or catalog["version"] != 1:
                    raise AuditFailure("invalid_workspace_inventory")
                for row in rows(catalog.get("entries")):
                    expected = workspace_documents.get(workspace_id(row.get("workspaceID")))
                    if expected is None or file_url(row.get("fileURL")) != expected:
                        raise AuditFailure("workspace_catalog_not_rehomed")
            elif path.name.startswith("AgentSession-") and path.suffix == ".json":
                if "subscriptionAccountBinding" in read_object(path):
                    raise AuditFailure("managed_session_present")
                session_count += 1

    return len(workspace_documents), session_count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", type=Path, required=True)
    parser.add_argument("--preferences", type=Path, required=True)
    parser.add_argument("--retained-root", type=Path, action="append", required=True)
    parser.add_argument("--max-settings-schema", type=int, required=True)
    args = parser.parse_args()
    try:
        workspace_count, session_count = audit(
            args.snapshot, args.preferences, args.retained_root, args.max_settings_schema
        )
    except AuditFailure as error:
        print(f"Rollback precheck refused: {error}")
        return 1
    except (OSError, ValueError, RuntimeError, plistlib.InvalidFileException, ExpatError):
        print("Rollback precheck refused: unreadable_or_invalid_snapshot")
        return 1
    print(f"No known rollback blocker in supplied snapshot: {workspace_count} workspace(s), {session_count} legacy session(s).")
    print("Static evidence only. Older-binary rehearsal and provider activation checks still required.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
