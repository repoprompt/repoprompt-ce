# RepoPrompt Server private pilot

This directory documents the non-publishing private-pilot server slice. The server remains an internal deployment artifact: CI builds and tests the image but does not authenticate to a registry, push an image, publish a package, or enable a distribution channel.

Operator documents:

- [Security and access](private-pilot-security.md)
- [Backup format and custody](backup-format-and-custody.md)
- [Backup, restore, and rotation runbook](backup-restore-runbook.md)
- [Operations runbook](operations-runbook.md)
- [Custody and external-gate record](private-pilot-custody-record.md)
- [Validation evidence and limitations](private-pilot-validation.md)

Schema V9 is the first private-pilot security/operations schema. Schema V7 and V8 definitions and frozen fixtures remain unchanged.
