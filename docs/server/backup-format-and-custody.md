# Backup format, receipts, and custody

The encrypted backup format remains immutable V1. A backup consists of:

- an age-encrypted ustar archive;
- an authenticated manifest inside the archive;
- an owner-only JSON sidecar beside the archive;
- external assets described as included, required, or optional by digest.

The manifest and sidecar bind the source store ID, schema version, next global sequence, namespace kind and identity digest, asset inventory, recipient fingerprints, tool version, and tool digest. Verification checks archive, manifest, asset, identity-recipient, and pinned-tool evidence before any restore publication.

Schema V9 adds **database receipts** without changing V1 backup bytes or Schema V7/V8:

- `backupCreate` after successful leased creation;
- `backupVerify` after successful verification performed with an explicitly leased source database;
- `migrationVerify` in the V8-to-V9 migration transaction;
- `restorePrepare` only after a fenced restore activates successfully.

Receipts retain digests, public recipient/verifier fingerprints, source evidence, correlation ID, and tool identity. They never retain age identities, passwords, setup/session tokens, key paths, or raw credentials.

## Custody rules

- Use at least two approved age recipients held by separate custodians for pilot backups.
- Store the encrypted archive and sidecar together; store age identities separately.
- Record fingerprints, not public recipient strings or private identities, in the custody record.
- Treat the sidecar as evidence, not authority: always run `backup verify` before migration or restore.
- Rotation is complete only after a new backup is created for the new recipient set and a restore drill succeeds.
- Destruction of old identities is a human custody action and must not occur until the release owner accepts the drill evidence.

The repository and CI contain no backup identity and no registry/release publishing credential.
