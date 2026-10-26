#!/usr/bin/env python3
"""Offline classifier for captured RepoPrompt CE local signing identity data.

This tool intentionally cannot read a Keychain or execute ``security``/``openssl``.
It accepts only a JSON fixture captured by a separately approved process.
"""

from __future__ import annotations

import argparse
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

DEFAULT_CERTIFICATE_NAME = "RepoPrompt CE Local Self-Signed Code Signing"
IDENTITY_PATTERN = re.compile(
    r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"]+)"(?:\s+\(([^)]*)\))?',
    re.MULTILINE,
)


def parse_identity_output(output: str, certificate_name: str) -> list[dict[str, str | None]]:
    identities: list[dict[str, str | None]] = []
    seen_sha1: set[str] = set()
    for match in IDENTITY_PATTERN.finditer(output):
        sha1, name, diagnostic = match.groups()
        normalized_sha1 = sha1.upper()
        if name == certificate_name and normalized_sha1 not in seen_sha1:
            seen_sha1.add(normalized_sha1)
            identities.append(
                {
                    "sha1": normalized_sha1,
                    "name": name,
                    "diagnostic": diagnostic,
                }
            )
    return identities


def normalized_fingerprint(value: str, *, expected_length: int) -> str:
    normalized = value.replace(":", "").strip().upper()
    if len(normalized) != expected_length or not re.fullmatch(r"[0-9A-F]+", normalized):
        raise ValueError(f"Invalid fingerprint: {value!r}")
    return normalized


def parse_iso_datetime(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError(f"Timestamp must include a timezone: {value!r}")
    return parsed.astimezone(timezone.utc)


def validity_state(not_before: datetime, not_after: datetime, now: datetime) -> str:
    if now < not_before:
        return "not_yet_valid"
    if now > not_after:
        return "expired"
    return "valid"


def certificate_record(
    captured: dict[str, Any],
    *,
    all_identity_sha1: set[str],
    valid_identity_sha1: set[str],
    now: datetime,
) -> dict[str, Any]:
    subject = str(captured["subject"])
    common_name = str(captured["common_name"])
    not_before = parse_iso_datetime(str(captured["not_before"]))
    not_after = parse_iso_datetime(str(captured["not_after"]))
    sha1 = normalized_fingerprint(str(captured["sha1"]), expected_length=40)
    return {
        "subject": subject,
        "subject_common_name": common_name,
        "serial": str(captured["serial"]),
        "not_before": not_before.isoformat(),
        "not_after": not_after.isoformat(),
        "validity": validity_state(not_before, not_after, now),
        "sha1": sha1,
        "sha256": normalized_fingerprint(str(captured["sha256"]), expected_length=64),
        "private_key_backed": sha1 in all_identity_sha1,
        "valid_code_signing_identity": sha1 in valid_identity_sha1,
    }


def collect_inventory(fixture: dict[str, Any], *, now: datetime) -> dict[str, Any]:
    certificate_name = str(fixture.get("certificate_name", DEFAULT_CERTIFICATE_NAME))
    all_identities = parse_identity_output(str(fixture.get("all_identity_output", "")), certificate_name)
    valid_identities = parse_identity_output(str(fixture.get("valid_identity_output", "")), certificate_name)
    all_identity_sha1 = {str(identity["sha1"]) for identity in all_identities}
    valid_identity_sha1 = {str(identity["sha1"]) for identity in valid_identities}
    if not valid_identity_sha1.issubset(all_identity_sha1):
        missing = sorted(valid_identity_sha1 - all_identity_sha1)
        raise ValueError(f"Valid identities missing from all identities: {missing}")

    certificates = [
        certificate_record(
            captured,
            all_identity_sha1=all_identity_sha1,
            valid_identity_sha1=valid_identity_sha1,
            now=now,
        )
        for captured in fixture.get("certificates", [])
    ]
    exact_certificates = [certificate for certificate in certificates if certificate["subject_common_name"] == certificate_name]
    certificate_sha1 = {str(certificate["sha1"]) for certificate in exact_certificates}

    return {
        "schema_version": 1,
        "source": "offline-fixture",
        "capture_label": str(fixture.get("capture_label", "unspecified")),
        "certificate_name": certificate_name,
        "evaluated_at": now.astimezone(timezone.utc).isoformat(),
        "summary": {
            "exact_name_certificate_count": len(exact_certificates),
            "private_key_backed_identity_count": sum(bool(certificate["private_key_backed"]) for certificate in exact_certificates),
            "valid_private_key_backed_identity_count": sum(bool(certificate["valid_code_signing_identity"]) for certificate in exact_certificates),
            "certificate_without_private_key_count": sum(not bool(certificate["private_key_backed"]) for certificate in exact_certificates),
            "duplicate_certificate_count": max(0, len(exact_certificates) - 1),
            "distinct_sha1_count": len(certificate_sha1),
            "unmatched_identity_count": len(all_identity_sha1 - certificate_sha1),
        },
        "certificates": exact_certificates,
        "all_exact_name_identities": all_identities,
        "valid_exact_name_identities": valid_identities,
        "unmatched_identity_sha1": sorted(all_identity_sha1 - certificate_sha1),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", required=True, help="Captured JSON input; this tool never reads a Keychain")
    parser.add_argument("--at", help="Evaluation timestamp; defaults to fixture evaluated_at or current UTC time")
    parser.add_argument("--output")
    arguments = parser.parse_args()

    fixture = json.loads(Path(arguments.fixture).read_text(encoding="utf-8"))
    evaluation_value = arguments.at or fixture.get("evaluated_at")
    now = parse_iso_datetime(str(evaluation_value)) if evaluation_value else datetime.now(timezone.utc)
    inventory = collect_inventory(fixture, now=now)
    rendered = json.dumps(inventory, indent=2, sort_keys=True) + "\n"
    if arguments.output:
        Path(arguments.output).write_text(rendered, encoding="utf-8")
    else:
        print(rendered, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
