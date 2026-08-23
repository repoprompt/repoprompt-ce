# Backup, restore, and key-rotation runbook

All database-touching commands require the authority namespace maintenance lease. Stop the server using the deployment supervisor and verify no serving process owns the namespace before maintenance; do not delete lock files manually.

## Create

```bash
RepoPromptServer backup create \
  --database /var/lib/repoprompt/state/repoprompt.sqlite \
  --recipients-file /secure/backup-recipients.txt \
  --output /secure/backups/repoprompt-$(date -u +%Y%m%dT%H%M%SZ).age
```

Preserve stdout JSON as operation evidence. Confirm the archive and `.sidecar.json` are mode `0600`, then inspect the Operations portal for a `backupCreate` receipt.

## Verify

```bash
RepoPromptServer backup verify /secure/backups/repoprompt-….age \
  --identity-file /secure/age-identity.txt \
  --database /var/lib/repoprompt/state/repoprompt.sqlite
```

`--database` is explicit because it acquires the source maintenance lease and records `backupVerify`. Omitting it performs cryptographic verification and sidecar update only; no database receipt can be written. Production evidence must use the leased form.

## Restore drill

1. Provision an empty target namespace and all configured included-asset parent directories.
2. Generate an independent target database identity and a one-use activation token of at least 256 bits in an owner-only file.
3. Run `RepoPromptServer restore …` with the target bindings and identity file.
4. Start once with `REPOPROMPT_RESTORE_ACTIVATION_TOKEN_FILE` pointing at the activation token.
5. Verify readiness, schema V9 ledger validity, target identity, optional-asset degradation, and the `restorePrepare` receipt.
6. Exercise one project/session read and one bounded write through a headless contract test. Do not launch the macOS app.
7. Stop the drill server and remove only drill-owned state after the evidence is retained.

Restore publication uses a staging directory, durable file/directory synchronization, an incomplete marker, an activation request moved last, and a target maintenance lease whose inode is not replaced. Startup refuses a pending restore without the explicit activation token.

## Rotation

1. Add new recipients; retain old identities.
2. Create and leased-verify a new backup.
3. Complete the restore drill with a new identity.
4. Obtain the external security/operations/release-owner approvals recorded in the custody ledger.
5. Only then retire old identities under the organization’s credential-destruction process.

If any checksum, recipient, namespace, external-asset, publication, or activation check fails, stop. Preserve archive, sidecar, structured logs, and database receipts; do not edit the sidecar or activation request to bypass a fence.
