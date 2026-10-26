#!/usr/bin/env python3
"""Inventory and resolve the RepoPrompt CE local code-signing identity.

The production inventory reads command output from ``security`` and ``openssl``.
Tests may pass an offline JSON fixture so no Keychain command is executed.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import stat
import subprocess
import sys
import tempfile
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
FINGERPRINT_PATTERN = re.compile(r"^[0-9A-F]{64}$")
SHA1_PATTERN = re.compile(r"^[0-9A-F]{40}$")
IDENTITY_LINE_PATTERN = re.compile(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"(.*)"\s*$')
PEM_PATTERN = re.compile(
    rb"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----",
    re.DOTALL,
)


class IdentityError(RuntimeError):
    pass


@dataclass(frozen=True)
class CertificateRecord:
    certificateName: str
    sha1: str
    sha256: str
    notAfter: str
    hasPrivateKey: bool
    isExpired: bool


@dataclass(frozen=True)
class RegistryRecord:
    schemaVersion: int
    certificateName: str
    certificateSHA256: str
    serviceGeneration: int


def normalize_fingerprint(value: str, length: int = 64) -> str:
    normalized = "".join(character for character in value.upper() if character in "0123456789ABCDEF")
    expected = FINGERPRINT_PATTERN if length == 64 else SHA1_PATTERN
    if not expected.fullmatch(normalized):
        raise IdentityError(f"Expected a {length}-character hexadecimal certificate fingerprint.")
    return normalized


def run_command(arguments: list[str], *, input_data: bytes | None = None) -> bytes:
    result = subprocess.run(arguments, input=input_data, capture_output=True, check=False)
    if result.returncode != 0:
        stderr = result.stderr.decode("utf-8", errors="replace").strip()
        raise IdentityError(f"Command failed ({' '.join(arguments)}): {stderr or 'no diagnostic output'}")
    return result.stdout


def parse_identity_hashes(output: str, certificate_name: str) -> set[str]:
    hashes: set[str] = set()
    for line in output.splitlines():
        match = IDENTITY_LINE_PATTERN.match(line)
        if match and match.group(2) == certificate_name:
            hashes.add(match.group(1).upper())
    return hashes


def openssl_field(pem: bytes, arguments: list[str]) -> str:
    output = run_command(["openssl", "x509", "-noout", *arguments], input_data=pem)
    return output.decode("utf-8", errors="replace").strip()


def parse_subject_common_name(subject: str) -> str:
    value = subject.split("=", 1)[1] if subject.startswith("subject=") else subject
    match = re.search(r"(?:^|,)CN=([^,]+)", value)
    return match.group(1).replace(r"\,", ",").strip() if match else ""


def parse_fingerprint(output: str, length: int) -> str:
    value = output.rsplit("=", 1)[-1]
    return normalize_fingerprint(value, length=length)


def parse_not_after(output: str) -> datetime:
    value = output.split("=", 1)[-1].strip()
    try:
        return datetime.strptime(value, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=timezone.utc)
    except ValueError as error:
        raise IdentityError(f"Could not parse certificate expiry '{value}'.") from error


def inventory_from_commands(certificate_name: str, keychain: str, evaluated_at: datetime) -> dict[str, Any]:
    identity_output = run_command(
        ["security", "find-identity", "-v", "-p", "codesigning", keychain]
    ).decode("utf-8", errors="replace")
    identity_hashes = parse_identity_hashes(identity_output, certificate_name)

    certificate_result = subprocess.run(
        ["security", "find-certificate", "-a", "-c", certificate_name, "-p", keychain],
        capture_output=True,
        check=False,
    )
    if certificate_result.returncode not in (0, 44):
        stderr = certificate_result.stderr.decode("utf-8", errors="replace").strip()
        raise IdentityError(
            "Command failed (security find-certificate): " + (stderr or "no diagnostic output")
        )
    certificate_output = certificate_result.stdout
    records: list[CertificateRecord] = []
    matched_identity_hashes: set[str] = set()
    for pem_match in PEM_PATTERN.finditer(certificate_output):
        pem = pem_match.group(0) + b"\n"
        subject = openssl_field(pem, ["-subject", "-nameopt", "RFC2253"])
        common_name = parse_subject_common_name(subject)
        if common_name != certificate_name:
            continue
        sha1 = parse_fingerprint(openssl_field(pem, ["-fingerprint", "-sha1"]), 40)
        sha256 = parse_fingerprint(openssl_field(pem, ["-fingerprint", "-sha256"]), 64)
        not_after_value = openssl_field(pem, ["-enddate"])
        not_after = parse_not_after(not_after_value)
        has_private_key = sha1 in identity_hashes
        if has_private_key:
            matched_identity_hashes.add(sha1)
        records.append(
            CertificateRecord(
                certificateName=common_name,
                sha1=sha1,
                sha256=sha256,
                notAfter=not_after.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
                hasPrivateKey=has_private_key,
                isExpired=not_after <= evaluated_at,
            )
        )

    missing_certificates = sorted(identity_hashes - matched_identity_hashes)
    if missing_certificates:
        raise IdentityError(
            "Could not export certificates for exact-name identities: " + ", ".join(missing_certificates)
        )
    return make_inventory(certificate_name, records, evaluated_at)


def inventory_from_fixture(path: Path, certificate_name: str, evaluated_at: datetime) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    records = [CertificateRecord(**record) for record in payload.get("certificates", [])]
    return make_inventory(certificate_name, records, evaluated_at)


def make_inventory(
    certificate_name: str,
    records: list[CertificateRecord],
    evaluated_at: datetime,
) -> dict[str, Any]:
    matching = [record for record in records if record.certificateName == certificate_name]
    candidates_by_fingerprint: dict[str, CertificateRecord] = {}
    normalized_records: list[CertificateRecord] = []
    for record in matching:
        sha1 = normalize_fingerprint(record.sha1, 40)
        sha256 = normalize_fingerprint(record.sha256, 64)
        try:
            not_after = datetime.fromisoformat(record.notAfter.replace("Z", "+00:00"))
        except ValueError as error:
            raise IdentityError(f"Could not parse fixture expiry '{record.notAfter}'.") from error
        normalized = CertificateRecord(
            certificateName=record.certificateName,
            sha1=sha1,
            sha256=sha256,
            notAfter=not_after.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
            hasPrivateKey=bool(record.hasPrivateKey),
            isExpired=bool(record.isExpired or not_after <= evaluated_at),
        )
        normalized_records.append(normalized)
        if normalized.hasPrivateKey and not normalized.isExpired:
            candidates_by_fingerprint[sha256] = normalized

    candidates = sorted(candidates_by_fingerprint.values(), key=lambda item: item.sha256)
    normalized_records.sort(key=lambda item: (item.sha256, item.sha1))
    return {
        "schemaVersion": SCHEMA_VERSION,
        "certificateName": certificate_name,
        "evaluatedAt": evaluated_at.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
        "candidates": [asdict(record) for record in candidates],
        "matchingCertificates": [asdict(record) for record in normalized_records],
    }


def read_registry(path: Path) -> RegistryRecord | None:
    try:
        details = path.lstat()
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(details.st_mode):
        raise IdentityError(f"Local signing identity registry is not a regular file: {path}")
    if details.st_uid != os.getuid():
        raise IdentityError(f"Local signing identity registry is not owned by the current user: {path}")
    if stat.S_IMODE(details.st_mode) & 0o077:
        raise IdentityError(f"Local signing identity registry must have owner-only permissions (0600): {path}")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
        record = RegistryRecord(**payload)
    except (OSError, TypeError, json.JSONDecodeError) as error:
        raise IdentityError(f"Local signing identity registry is invalid: {path}") from error
    if record.schemaVersion != SCHEMA_VERSION:
        raise IdentityError(f"Unsupported local signing identity registry version: {record.schemaVersion}")
    normalize_fingerprint(record.certificateSHA256)
    if not record.certificateName or record.serviceGeneration < 1:
        raise IdentityError(f"Local signing identity registry has invalid fields: {path}")
    return record


def write_registry(path: Path, record: RegistryRecord) -> None:
    if record.schemaVersion != SCHEMA_VERSION or record.serviceGeneration < 1:
        raise IdentityError("Refusing to write an invalid local signing identity registry record.")
    normalize_fingerprint(record.certificateSHA256)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary_path = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(asdict(record), handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_path, path)
        directory_descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    finally:
        if temporary_path.exists():
            temporary_path.unlink()


def load_inventory(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("schemaVersion") != SCHEMA_VERSION:
        raise IdentityError("Unsupported local signing identity inventory version.")
    return payload


def normalized_candidates(inventory: dict[str, Any]) -> list[dict[str, Any]]:
    candidates = inventory.get("candidates")
    if not isinstance(candidates, list):
        raise IdentityError("Local signing identity inventory is missing candidates.")
    result: list[dict[str, Any]] = []
    for candidate in candidates:
        if not isinstance(candidate, dict):
            raise IdentityError("Local signing identity inventory contains an invalid candidate.")
        normalized = dict(candidate)
        normalized["sha1"] = normalize_fingerprint(str(candidate.get("sha1", "")), 40)
        normalized["sha256"] = normalize_fingerprint(str(candidate.get("sha256", "")), 64)
        result.append(normalized)
    return sorted(result, key=lambda item: item["sha256"])


def new_service_generation() -> int:
    return (1 << 61) | secrets.randbits(61)


def resolve_plan(
    inventory: dict[str, Any],
    registry: RegistryRecord | None,
    selected_fingerprint: str | None,
    rotate: bool,
) -> dict[str, Any]:
    certificate_name = str(inventory.get("certificateName", ""))
    candidates = normalized_candidates(inventory)
    by_fingerprint = {candidate["sha256"]: candidate for candidate in candidates}
    selected = normalize_fingerprint(selected_fingerprint) if selected_fingerprint else None

    if registry is not None and registry.certificateName != certificate_name:
        raise IdentityError("Registered local signing certificate name does not match installer policy.")

    if registry is not None and not rotate:
        registered = normalize_fingerprint(registry.certificateSHA256)
        if selected and selected != registered:
            raise IdentityError(
                "A different local signing fingerprint is already registered. "
                "Set ROTATE_LOCAL_SIGNING_IDENTITY=1 to rotate explicitly."
            )
        candidate = by_fingerprint.get(registered)
        if candidate is None:
            matching = inventory.get("matchingCertificates", [])
            known = next((item for item in matching if item.get("sha256") == registered), None)
            if known and known.get("isExpired"):
                reason = "expired"
            elif known and not known.get("hasPrivateKey"):
                reason = "does not have an available private key"
            else:
                reason = "is missing"
            raise IdentityError(
                f"Registered local signing identity {registered} {reason}; refusing to mint or adopt a replacement. "
                "Restore the identity or rotate explicitly with ROTATE_LOCAL_SIGNING_IDENTITY=1."
            )
        return {
            "action": "use",
            "candidate": candidate,
            "serviceGeneration": registry.serviceGeneration,
            "registryNeedsWrite": False,
        }

    if registry is not None and rotate:
        registered = normalize_fingerprint(registry.certificateSHA256)
        if selected:
            if selected == registered:
                raise IdentityError("Rotation requires a different certificate fingerprint.")
            candidate = by_fingerprint.get(selected)
            if candidate is None:
                raise IdentityError(f"Selected rotation fingerprint is not a valid exact-name identity: {selected}")
            return {
                "action": "rotate",
                "candidate": candidate,
                "serviceGeneration": registry.serviceGeneration + 1,
                "registryNeedsWrite": True,
                "previousFingerprint": registered,
            }
        return {
            "action": "mint",
            "candidate": None,
            "serviceGeneration": registry.serviceGeneration + 1,
            "registryNeedsWrite": True,
            "previousFingerprint": registered,
        }

    if rotate:
        raise IdentityError("No local signing identity is registered; rotation is not applicable on first use.")
    initial_generation = new_service_generation()
    if selected:
        candidate = by_fingerprint.get(selected)
        if candidate is None:
            raise IdentityError(f"Selected fingerprint is not a valid exact-name identity: {selected}")
        return {
            "action": "adopt",
            "candidate": candidate,
            "serviceGeneration": initial_generation,
            "registryNeedsWrite": True,
        }
    if not candidates:
        return {
            "action": "mint",
            "candidate": None,
            "serviceGeneration": initial_generation,
            "registryNeedsWrite": True,
        }
    if len(candidates) == 1:
        return {
            "action": "adopt",
            "candidate": candidates[0],
            "serviceGeneration": initial_generation,
            "registryNeedsWrite": True,
        }
    fingerprints = "\n".join(f"  - {candidate['sha256']}" for candidate in candidates)
    raise IdentityError(
        "Multiple valid exact-name local signing identities exist; refusing first-match selection.\n"
        f"{fingerprints}\n"
        "Re-run with LOCAL_SIGNING_IDENTITY_SHA256=<fingerprint> to register one explicitly."
    )


def select_new_candidate(before: dict[str, Any], after: dict[str, Any]) -> dict[str, Any]:
    before_fingerprints = {candidate["sha256"] for candidate in normalized_candidates(before)}
    added = [candidate for candidate in normalized_candidates(after) if candidate["sha256"] not in before_fingerprints]
    if len(added) != 1:
        fingerprints = ", ".join(candidate["sha256"] for candidate in added) or "none"
        raise IdentityError(f"Expected exactly one newly minted valid identity, found: {fingerprints}")
    return added[0]


def evaluation_time(value: str | None) -> datetime:
    if not value:
        return datetime.now(timezone.utc)
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise IdentityError(f"Invalid evaluation timestamp: {value}") from error
    return parsed.astimezone(timezone.utc)


def emit(payload: Any) -> None:
    json.dump(payload, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    inventory_parser = subparsers.add_parser("inventory")
    inventory_parser.add_argument("--certificate-name", required=True)
    inventory_parser.add_argument("--keychain", required=True)
    inventory_parser.add_argument("--fixture")
    inventory_parser.add_argument("--at")

    plan_parser = subparsers.add_parser("plan")
    plan_parser.add_argument("--inventory", required=True)
    plan_parser.add_argument("--registry", required=True)
    plan_parser.add_argument("--select")
    plan_parser.add_argument("--rotate", action="store_true")

    new_parser = subparsers.add_parser("select-new")
    new_parser.add_argument("--before", required=True)
    new_parser.add_argument("--after", required=True)

    write_parser = subparsers.add_parser("write-registry")
    write_parser.add_argument("--path", required=True)
    write_parser.add_argument("--certificate-name", required=True)
    write_parser.add_argument("--fingerprint", required=True)
    write_parser.add_argument("--generation", required=True, type=int)

    read_parser = subparsers.add_parser("read-registry")
    read_parser.add_argument("--path", required=True)

    arguments = parser.parse_args()
    try:
        if arguments.command == "inventory":
            at = evaluation_time(arguments.at)
            if arguments.fixture:
                payload = inventory_from_fixture(Path(arguments.fixture), arguments.certificate_name, at)
            else:
                payload = inventory_from_commands(arguments.certificate_name, arguments.keychain, at)
            emit(payload)
        elif arguments.command == "plan":
            payload = resolve_plan(
                load_inventory(Path(arguments.inventory)),
                read_registry(Path(arguments.registry)),
                arguments.select,
                arguments.rotate,
            )
            emit(payload)
        elif arguments.command == "select-new":
            emit(select_new_candidate(load_inventory(Path(arguments.before)), load_inventory(Path(arguments.after))))
        elif arguments.command == "write-registry":
            record = RegistryRecord(
                schemaVersion=SCHEMA_VERSION,
                certificateName=arguments.certificate_name,
                certificateSHA256=normalize_fingerprint(arguments.fingerprint),
                serviceGeneration=arguments.generation,
            )
            write_registry(Path(arguments.path), record)
            emit(asdict(record))
        elif arguments.command == "read-registry":
            record = read_registry(Path(arguments.path))
            if record is None:
                raise IdentityError(f"Local signing identity registry does not exist: {arguments.path}")
            emit(asdict(record))
    except (IdentityError, OSError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
