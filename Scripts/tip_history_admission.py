#!/usr/bin/env python3
"""Release-only admission and manifest bindings for the Tip history CLI.

No key access or GitHub mutations. Source, seed and retention audits are explicit
inputs; missing reviewed evidence is a hard error, never a permissive bootstrap.
"""
from __future__ import annotations

import argparse
import hashlib
import subprocess
import sys
from pathlib import Path

sys.dont_write_bytecode = True
import stable_rollout as rollout
import tip_history as history


def load_policy(path: Path) -> dict:
    policy = history.read_json(path)
    history.require(policy.get("schemaVersion") == 1, "unsupported history policy")
    floor = policy.get("historyAdmissionFloorBuild")
    commit = policy.get("historyAdmissionFloorCommit")
    history.require(isinstance(floor, str) and isinstance(commit, str) and history.COMMIT.fullmatch(commit) is not None, "history admission requires a reviewed build/commit floor")
    rollout.parse_build(floor, "history admission floor")
    history.require("historyUIFloorBuild" in policy, "history policy requires historyUIFloorBuild (nullable)")
    ui_floor = policy["historyUIFloorBuild"]
    history.require(ui_floor is None or isinstance(ui_floor, str), "history UI floor must be a build string or null")
    if ui_floor is not None:
        rollout.parse_build(ui_floor, "history UI floor")
    history.require("historyEnabledSinceTag" in policy, "history policy requires historyEnabledSinceTag (nullable)")
    activation = policy["historyEnabledSinceTag"]
    history.require(activation is None or isinstance(activation, str) and history.TAG.fullmatch(activation) is not None, "history activation tag must be a Tip tag or null")
    return policy


def require_retention_review(policy: dict) -> None:
    retention = policy.get("retention")
    history.require(isinstance(retention, dict) and type(retention.get("schemaLifetime")) is int and retention["schemaLifetime"] == 1 and isinstance(retention.get("owner"), str) and retention["owner"].strip() and isinstance(retention.get("reviewedEvidence"), str) and retention["reviewedEvidence"].strip(), "Tip history retention/cleanup settings require reviewed evidence before publication")


def admit_source(policy: dict, source: Path, commit: str, build: str) -> None:
    history.require(rollout.parse_build(build, "history entry") >= rollout.parse_build(policy["historyAdmissionFloorBuild"], "history floor"), "entry predates the audited history admission floor")
    history.require(history.is_ancestor(source, policy["historyAdmissionFloorCommit"], commit), "release source does not descend from the audited admission floor")


def entry_from_manifest(*, apple_policy: dict, policy: dict, source: Path, manifest_path: Path, artifact_path: Path, notes: dict, expanded_size: int | None, origin: str = "catalog") -> dict:
    manifest = rollout.validate_tip_manifest_pair(apple_policy, manifest_path, manifest_path.with_name("appcast.xml"), "history candidate")
    artifact = history.read_json(artifact_path)
    binding = manifest["appArtifactManifest"]
    history.require(binding["name"] == artifact_path.name and binding["sha256"] == rollout.sha256_file(artifact_path), "history app artifact manifest binding mismatch")
    head = manifest["appcastItems"][0]
    commit = manifest["releaseCommit"]
    build = manifest["buildNumber"]
    admit_source(policy, source, commit, build)
    history.require(notes.get("releaseCommit") == commit, "release notes candidate commit mismatch")
    interval = notes.get("commitRange", {})
    regenerated = history.collect_notes(source, interval.get("fromCommit"), commit)
    history.require(history.canonical(regenerated) == history.canonical(notes), "release notes differ from approved source history")
    history.require(manifest["sourceTag"] == "tip-" + commit[:12], "history tag/commit mismatch")
    bundle = artifact.get("bundle", {})
    signing = artifact.get("bundle_signing", {})
    for artifact_key, manifest_key in (("identifier", "bundleIdentifier"), ("marketing_version", "marketingVersion"), ("build_number", "buildNumber")):
        history.require(bundle.get(artifact_key) == manifest[manifest_key], f"history artifact {artifact_key} mismatch")
    history.require(signing.get("team_identifier") == manifest["teamIdentifier"], "history artifact signing Team ID mismatch")
    history.require(artifact.get("schema_version") == 1, "history requires a final artifact manifest schema 1")
    expected_signing_mode = rollout.SIGNING_MODE_BY_IDENTITY[manifest["signingIdentity"]]
    history.require(bundle.get("signing_mode") == expected_signing_mode, f"history artifact signing mode must be {expected_signing_mode} for {manifest['signingIdentity']}")
    architectures = bundle.get("architectures")
    history.require(isinstance(architectures, list) and len(architectures) == 2 and set(architectures) == {"arm64", "x86_64"}, "final Tip artifact must be universal arm64+x86_64")
    executables = artifact.get("executables")
    history.require(isinstance(executables, list) and executables, "final app artifact requires executable architecture inventory")
    for executable in executables:
        history.require(isinstance(executable, dict) and set(executable.get("architectures", [])) == set(architectures), "artifact executable architectures disagree")
    download = None
    if head["installationType"] == "application":
        history.require(type(expanded_size) is int and 0 < expanded_size <= 8 * 1024**3, "history application requires an audited expanded byte count")
        download = {"name": head["enclosureName"], "url": head["url"], "size": head["enclosureSize"], "expandedSize": expanded_size, "sha256": head["enclosureSha256"], "edSignature": head["edSignature"]}
        history.require(0 < download["size"] <= 2 * 1024**3, "archive exceeds history bounds")
    ui_floor = policy.get("historyUIFloorBuild")
    entry = {
        "tag": manifest["sourceTag"], "releaseCommit": commit, "shortSHA": commit[:12],
        "commitDate": notes["commitDate"], "buildNumber": build, "marketingVersion": manifest["marketingVersion"],
        "role": manifest["currentRole"], "signingIdentity": manifest["signingIdentity"],
        "bundleIdentifier": manifest["bundleIdentifier"], "teamIdentifier": manifest["teamIdentifier"],
        "migrationPhase": manifest["migrationPhase"], "installationType": head["installationType"],
        "minimumSystemVersion": head["minimumSystemVersion"], "architectures": architectures,
        "title": notes["title"] or f"Tip build {build} · commit {commit[:12]}",
        "titleSource": notes["titleSource"], "notes": notes["notes"], "omittedCount": notes["omittedCount"],
        "commitRange": notes["commitRange"], "downgradeBarrier": notes["downgradeBarrier"],
        "downgradeBarrierReasons": notes["downgradeBarrierReasons"], "download": download,
        "historyCatalogSha256": None, "origin": origin,
        "hasHistoryUI": ui_floor is not None and rollout.parse_build(build, "entry") >= rollout.parse_build(ui_floor, "history UI floor"),
    }
    validate_entry(entry, apple_policy=apple_policy, policy=policy, source=source)
    return entry


def validate_entry(entry: dict, *, apple_policy: dict, policy: dict, source: Path) -> None:
    history.require(isinstance(entry, dict), "history entry must be object")
    commit = entry.get("releaseCommit")
    history.require(isinstance(commit, str) and history.COMMIT.fullmatch(commit) is not None and entry.get("shortSHA") == commit[:12] and entry.get("tag") == "tip-" + commit[:12], "invalid history release provenance")
    history.require(isinstance(entry.get("buildNumber"), str), "history build must be a string")
    admit_source(policy, source, commit, entry["buildNumber"])
    date = history.git(source, "show", "-s", "--format=%cI", commit).strip()
    history.require(entry.get("commitDate") == date, "history commit date differs from source")
    role = entry.get("role")
    history.require(role in rollout.ROLES, "unknown history role")
    identity_name = rollout.ROLE_IDENTITY[role]
    identity = apple_policy["identities"][identity_name]
    history.require(entry.get("signingIdentity") == identity_name and entry.get("bundleIdentifier") == identity["bundleIdentifier"] and entry.get("teamIdentifier") == identity["teamIdentifier"] and entry.get("migrationPhase") == rollout.ROLE_MIGRATION_PHASE[role] and entry.get("installationType") == rollout.ROLE_INSTALLATION_TYPE[role], "history identity/role mismatch")
    rollout.parse_build(entry.get("minimumSystemVersion", ""), "history minimum macOS")
    arch = entry.get("architectures")
    history.require(isinstance(arch, list) and arch and len(set(arch)) == len(arch) and set(arch) <= {"arm64", "x86_64"}, "invalid history architectures")
    history.require(entry.get("origin") in ("catalog", "seed") and type(entry.get("hasHistoryUI")) is bool, "invalid history origin/UI capability")
    title = entry.get("title")
    history.require(isinstance(title, str) and title and history.clean(title) == title and history.truncate_many([title], 90)[0] == title, "invalid history title")
    history.require(entry.get("titleSource") in ("commit", "reviewed"), "invalid title provenance")
    notes = entry.get("notes")
    history.require(isinstance(notes, list) and len(notes) <= 10, "invalid history notes")
    for note in notes:
        history.require(isinstance(note, dict) and note.get("source") in ("commit", "reviewed") and isinstance(note.get("text"), str) and note["text"] and history.clean(note["text"]) == note["text"] and history.truncate_many([note["text"]], 200)[0] == note["text"], "invalid history note")
    history.require(type(entry.get("omittedCount")) is int and entry["omittedCount"] >= 0, "invalid omitted note count")
    reasons = entry.get("downgradeBarrierReasons")
    history.require(type(entry.get("downgradeBarrier")) is bool and isinstance(reasons, list) and len(reasons) <= 3 and all(isinstance(reason, str) and reason and history.clean(reason) == reason and history.truncate_many([reason], 200)[0] == reason for reason in reasons) and (not entry["downgradeBarrier"] or reasons), "invalid downgrade barrier metadata")
    interval = entry.get("commitRange")
    history.require(isinstance(interval, dict) and type(interval.get("count")) is int and interval["count"] >= 0 and (interval.get("fromCommit") is None or isinstance(interval["fromCommit"], str) and history.COMMIT.fullmatch(interval["fromCommit"]) is not None), "invalid commit interval")
    prior = interval.get("fromCommit")
    safety = history.collect_notes(source, prior, commit)
    safety["title"] = safety["title"] or f"Tip build {entry['buildNumber']} · commit {commit[:12]}"
    for field in ("title", "titleSource", "notes", "omittedCount", "commitRange"):
        history.require(entry.get(field) == safety[field], f"history {field} differs from approved source interval")
    if safety["downgradeBarrier"]:
        history.require(entry["downgradeBarrier"], "source downgrade barrier cannot be removed")
    if prior is None or not history.is_ancestor(source, prior, commit):
        history.require(entry["downgradeBarrier"], "unprovable release continuity requires a blocking barrier")
    ui_floor = policy.get("historyUIFloorBuild")
    expected_ui = ui_floor is not None and rollout.parse_build(entry["buildNumber"], "entry") >= rollout.parse_build(ui_floor, "UI floor")
    history.require(entry["hasHistoryUI"] == expected_ui, "history UI capability differs from audited floor")
    download = entry.get("download")
    if role == "transition":
        history.require(download is None, "transition installer must not be downloadable")
    else:
        history.require(isinstance(download, dict), "application history entry requires download metadata")
        name = download.get("name")
        history.require(isinstance(name, str) and name.endswith(".zip") and "/" not in name and "\\" not in name and "%" not in name and history.clean(name) == name, "invalid history download name")
        expected = f"https://github.com/{rollout.update_repository(apple_policy, 'tip')}/releases/download/{entry['tag']}/{name}"
        history.require(download.get("url") == expected, "history download URL mismatch")
        history.require(type(download.get("size")) is int and 0 < download["size"] <= 2 * 1024**3 and type(download.get("expandedSize")) is int and 0 < download["expandedSize"] <= 8 * 1024**3, "history download bounds invalid")
        history.require(isinstance(download.get("sha256"), str) and history.DIGEST.fullmatch(download["sha256"]) is not None, "invalid enclosure digest")
        history.decode64(download.get("edSignature"), 64)


def build_payload(*, entry: dict, apple_policy: dict, policy: dict, source: Path, parent_bytes: bytes | None, bootstrap: dict | None = None) -> bytes:
    require_retention_review(policy)
    activation = policy.get("historyEnabledSinceTag")
    history.require(isinstance(activation, str) and history.TAG.fullmatch(activation) is not None, "reviewed history activation tag required")
    history.require(parent_bytes is None or bootstrap is None, "parent and bootstrap are mutually exclusive")
    validate_entry(entry, apple_policy=apple_policy, policy=policy, source=source)
    repository = rollout.update_repository(apple_policy, "tip")
    seeds = None
    if parent_bytes is None:
        history.require(policy.get("historyEnabledSinceTag") is not None and entry["tag"] == policy["historyEnabledSinceTag"], "bootstrap must match the reviewed activation tag")
        history.require(isinstance(bootstrap, dict) and bootstrap.get("schemaVersion") == 1 and bootstrap.get("historyNeverEnabled") is True and "liveParent" in bootstrap, "audited bootstrap evidence with explicit liveParent required")
        expected_digest = policy.get("bootstrapEvidenceSha256")
        history.require(isinstance(expected_digest, str) and hashlib.sha256(history.canonical(bootstrap)).hexdigest() == expected_digest, "bootstrap evidence differs from reviewed policy")
        seeds = bootstrap.get("entries")
        history.require(isinstance(seeds, list) and len(seeds) == 29, f"bootstrap requires 29 admitted predecessors; found {len(seeds) if isinstance(seeds, list) else 0}")
        for index, seed in enumerate(seeds):
            validate_entry(seed, apple_policy=apple_policy, policy=policy, source=source)
            history.require(seed["origin"] == "seed" and seed["historyCatalogSha256"] is None, "invalid seed catalog origin")
            if index + 1 < len(seeds):
                history.require(seed["commitRange"]["fromCommit"] == seeds[index + 1]["releaseCommit"], "seed source interval skips its reviewed predecessor")
        history.require(bootstrap["liveParent"] is None or bootstrap["liveParent"] == seeds[0]["tag"], "bootstrap newest seed differs from reviewed latest parent")
        expected_parent_commit = seeds[0]["releaseCommit"]
    else:
        parent = history.page_from_envelope(parent_bytes)
        for retained in parent["entries"]:
            validate_entry(retained, apple_policy=apple_policy, policy=policy, source=source)
        expected_parent_commit = parent["entries"][0]["releaseCommit"]
    history.require(entry["commitRange"]["fromCommit"] == expected_parent_commit, "candidate note range differs from the resolved catalog parent")
    return history.canonical(history.assemble_page(entry, repository, parent_bytes, seeds))


def verify_parent(parent_bytes: bytes, parent_tag: str | None = None, parent_sha256: str | None = None) -> None:
    """Check structure/tag/digest only. Shell MUST authenticate Ed25519 first."""
    page = history.page_from_envelope(parent_bytes)
    if parent_tag is not None:
        history.require(page["generatedForTag"] == parent_tag, f"parent tag mismatch: expected {parent_tag}, got {page['generatedForTag']}")
    if parent_sha256 is not None:
        actual = hashlib.sha256(parent_bytes).hexdigest()
        history.require(actual == parent_sha256, f"parent digest mismatch: expected {parent_sha256}, got {actual}")


def verify_candidate(candidate_bytes: bytes, apple_policy: dict, policy: dict, source: Path, manifest_path: Path, app_artifact_manifest_path: Path, expected_parent_bytes: bytes | None = None, bootstrap: dict | None = None, *, expanded_size: int | None = None) -> None:
    """Re-derive the head and entire page; caller authenticates envelopes first.

    expanded_size is independently measured from the final enclosure by shell,
    NOT copied from the candidate or a nonexistent artifact-manifest field.
    Notes are regenerated from approved Git data, not an unpublished sidecar.
    """
    candidate = history.page_from_envelope(candidate_bytes)
    head = candidate["entries"][0]
    validate_entry(head, apple_policy=apple_policy, policy=policy, source=source)
    manifest = history.read_json(manifest_path)
    notes = history.collect_notes(source, head["commitRange"]["fromCommit"], manifest["releaseCommit"])
    expected_head = entry_from_manifest(
        apple_policy=apple_policy, policy=policy, source=source,
        manifest_path=manifest_path, artifact_path=app_artifact_manifest_path,
        notes=notes, expanded_size=expanded_size,
    )
    history.require(history.canonical(head) == history.canonical(expected_head), "candidate head differs from rollout/artifact/source/expanded-size binding")
    expected = build_payload(entry=expected_head, apple_policy=apple_policy, policy=policy, source=source, parent_bytes=expected_parent_bytes, bootstrap=bootstrap)
    history.require(history.canonical(candidate) == expected, "Tip history parent superseded or candidate retained/seed payload differs")


def main() -> int:
    """File-based admission CLI; no signing keys or network access."""
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    build = sub.add_parser("build-payload", help="Generate signed catalog payload")
    build.add_argument("--policy", type=Path, required=True, help="Policy JSON file")
    build.add_argument("--apple-policy", type=Path, required=True, help="Apple identity policy")
    build.add_argument("--source", type=Path, required=True, help="Repository root for source ancestry")
    build.add_argument("--manifest", type=Path, required=True, help="identity-rollout.json manifest")
    build.add_argument("--app-artifact-manifest", type=Path, required=True, help="Artifact manifest JSON")
    build.add_argument("--notes", type=Path, required=True, help="Release notes JSON")
    build.add_argument("--expanded-size", type=int, required=True, help="Expanded app size in bytes")
    build_parent = build.add_mutually_exclusive_group(required=True)
    build_parent.add_argument("--parent-envelope", type=Path, help="Already-authenticated parent catalog")
    build_parent.add_argument("--bootstrap", type=Path, help="Policy-pinned audited bootstrap evidence")
    build.add_argument("--output", type=Path, required=True, help="Output payload file")

    verify_p = sub.add_parser("verify-parent", help="Validate parent envelope")
    verify_p.add_argument("--envelope", type=Path, required=True, help="Parent catalog envelope")
    verify_p.add_argument("--tag", help="Expected parent tag")
    verify_p.add_argument("--sha256", help="Expected parent digest")

    verify_c = sub.add_parser("verify-candidate", help="Validate candidate against manifest")
    verify_c.add_argument("--envelope", type=Path, required=True, help="Candidate catalog envelope")
    verify_c.add_argument("--apple-policy", type=Path, required=True, help="Apple identity policy")
    verify_c.add_argument("--policy", type=Path, required=True, help="Policy JSON file")
    verify_c.add_argument("--source", type=Path, required=True, help="Repository root")
    verify_c.add_argument("--manifest", type=Path, required=True, help="identity-rollout.json")
    verify_c.add_argument("--app-artifact-manifest", type=Path, required=True, help="Artifact manifest")
    verify_c.add_argument("--expanded-size", type=int, required=True, help="Independently verified final ZIP expanded bytes; 0 for package")
    verify_parent_args = verify_c.add_mutually_exclusive_group(required=True)
    verify_parent_args.add_argument("--parent-envelope", type=Path, help="Already-authenticated parent catalog")
    verify_parent_args.add_argument("--bootstrap", type=Path, help="Policy-pinned audited bootstrap evidence")

    args = parser.parse_args()
    try:
        if args.command == "verify-parent":
            verify_parent(args.envelope.read_bytes(), args.tag, args.sha256)
            return 0
        apple_policy = rollout.load_policy(args.apple_policy)
        manifest = history.read_json(args.manifest)
        history.require(history.git(args.source, "rev-parse", "HEAD").strip() == manifest["releaseCommit"], "source HEAD must match the approved candidate")
        history.require(history.git(args.source, "rev-parse", "--is-shallow-repository").strip() == "false", "full approved source history required")
        if args.command == "build-payload":
            policy = load_policy(args.policy)
            notes = history.read_json(args.notes)
            parent_bytes = args.parent_envelope.read_bytes() if args.parent_envelope else None
            bootstrap = history.read_json(args.bootstrap) if args.bootstrap else None
            entry = entry_from_manifest(apple_policy=apple_policy, policy=policy, source=args.source, manifest_path=args.manifest, artifact_path=args.app_artifact_manifest, notes=notes, expanded_size=args.expanded_size)
            payload = build_payload(entry=entry, apple_policy=apple_policy, policy=policy, source=args.source, parent_bytes=parent_bytes, bootstrap=bootstrap)
            args.output.write_bytes(payload)
        elif args.command == "verify-candidate":
            candidate_apple_policy = rollout.load_policy(args.apple_policy)
            policy = load_policy(args.policy)
            parent_bytes = args.parent_envelope.read_bytes() if args.parent_envelope else None
            bootstrap = history.read_json(args.bootstrap) if args.bootstrap else None
            verify_candidate(args.envelope.read_bytes(), candidate_apple_policy, policy, args.source, args.manifest, args.app_artifact_manifest, parent_bytes, bootstrap, expanded_size=args.expanded_size)
    except (history.HistoryError, rollout.RolloutError, OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        print(f"tip-history-admission: {error}", file=sys.__stderr__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
