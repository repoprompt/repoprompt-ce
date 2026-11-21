import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from uuid import UUID

from audit_subscription_rollback import AuditFailure, audit


class SubscriptionRollbackAuditTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        parent = Path(temp.name).resolve()
        self.root = parent / "snapshot"
        self.active = parent / "retained"
        self.external = parent / "retained-custom-sessions"
        self.active.mkdir()
        self.external.mkdir()
        self.preferences = self.root / "old-preferences.plist"
        self.workspace_id = str(UUID(int=1))
        self.workspace = self.root / "Workspaces" / "Isolated"
        self.settings = self.root / "Settings" / "globalSettings.json"
        self.index = self.root / "Workspaces" / "workspacesIndex.json"
        self.catalog = self.root / "DomainRuntime" / "v1" / "old" / "workspace-catalog.json"
        self.session = self.workspace / "AgentSessions" / f"AgentSession-{UUID(int=2)}.json"
        self.write(self.settings, {"schemaVersion": 14, "schemaLineage": "repoprompt-ce.global-settings"})
        self.preferences.write_bytes(plistlib.dumps({}))
        self.write(self.index, [{"id": self.workspace_id}])
        self.write(self.workspace / "workspace.json", {"id": self.workspace_id})
        self.write(self.catalog, {"version": 1, "entries": [self.catalog_entry(self.workspace)]})
        self.write(self.session, {"serializationVersion": 9, "name": "Legacy"})

    @staticmethod
    def write(path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value), encoding="utf-8")

    def catalog_entry(self, directory):
        return {"workspaceID": self.workspace_id, "fileURL": (directory / "workspace.json").as_uri()}

    def run_audit(self):
        return audit(self.root, self.preferences, [self.active, self.external], 14)

    def test_isolated_legacy_profile_passes_without_changes(self):
        before = {p: p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        self.assertEqual(self.run_audit(), (1, 1))
        self.assertEqual({p: p.read_bytes() for p in self.root.rglob("*") if p.is_file()}, before)

    def test_refuses_custom_path_in_both_workspace_readers(self):
        for path, is_index in [(self.index, True), (self.workspace / "workspace.json", False)]:
            with self.subTest(path=path.name):
                original = path.read_bytes()
                row = {"id": self.workspace_id, "customStoragePath": self.external.as_uri()}
                self.write(path, [row] if is_index else row)
                with self.assertRaisesRegex(AuditFailure, "custom_storage_not_rehomed"):
                    self.run_audit()
                path.write_bytes(original)

    def test_refuses_retained_catalog_and_global_preference_routes(self):
        self.write(self.catalog, {"version": 1, "entries": [self.catalog_entry(self.external)]})
        with self.assertRaisesRegex(AuditFailure, "workspace_catalog_not_rehomed"):
            self.run_audit()
        self.write(self.catalog, {"version": 1, "entries": [self.catalog_entry(self.workspace)]})
        self.preferences.write_bytes(plistlib.dumps({"GlobalCustomStorageURL": str(self.external)}))
        with self.assertRaisesRegex(AuditFailure, "global_custom_storage_override"):
            self.run_audit()

    def test_refuses_managed_data_even_with_null_binding_or_legacy_schema(self):
        self.write(self.session, {"subscriptionAccountBinding": None})
        with self.assertRaisesRegex(AuditFailure, "managed_session_present"):
            self.run_audit()
        self.write(self.session, {"serializationVersion": 9})
        self.write(self.settings, {"schemaVersion": 14, "schemaLineage": "repoprompt-ce.global-settings",
                                   "scalarPreferences": {"subscriptionProfileCatalog": {}}})
        with self.assertRaisesRegex(AuditFailure, "managed_catalog_present"):
            self.run_audit()
        self.write(self.settings, {"schemaVersion": 15})
        with self.assertRaisesRegex(AuditFailure, "settings_schema_unsupported"):
            self.run_audit()

    def test_checks_working_journal_location_independently_of_catalog(self):
        journals = self.catalog.parent / "working-journals"
        journal = journals / f"{self.workspace_id}.json"
        self.write(journal, {"version": 1, **self.catalog_entry(self.workspace)})
        self.assertEqual(self.run_audit(), (1, 1))
        self.write(journal, {"version": 1, **self.catalog_entry(self.external)})
        with self.assertRaisesRegex(AuditFailure, "workspace_journal_not_rehomed"):
            self.run_audit()

        journal.unlink()
        orphan = str(UUID(int=3))
        self.write(journals / f"{orphan}.json", {
            "version": 1,
            "workspaceID": orphan,
            "fileURL": (self.external / "workspace.json").as_uri(),
        })
        with self.assertRaisesRegex(AuditFailure, "workspace_journal_not_rehomed"):
            self.run_audit()

    def test_refuses_unknown_schema_even_below_ceiling_and_linked_input(self):
        for payload in [
            {"schemaVersion": 5},
            {"schemaVersion": 6, "schemaLineage": "repoprompt-ce.global-settings"},
            {"schemaVersion": 2, "schemaLineage": "foreign"},
        ]:
            with self.subTest(payload=payload):
                self.write(self.settings, payload)
                with self.assertRaisesRegex(AuditFailure, "settings_schema_unsupported"):
                    self.run_audit()
        alias = self.root.parent / "snapshot-alias"
        alias.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(AuditFailure, "invalid_snapshot_root"):
            audit(alias, alias / self.preferences.name, [self.active], 14)

    def test_refuses_duplicate_workspace_identity_across_documents(self):
        self.write(self.root / "Workspaces" / "Duplicate" / "workspace.json", {"id": self.workspace_id.upper()})
        with self.assertRaisesRegex(AuditFailure, "duplicate_workspace_identity"):
            self.run_audit()

    def test_refuses_retained_nested_paths_links_and_duplicate_keys(self):
        with self.assertRaisesRegex(AuditFailure, "snapshot_overlaps_retained_storage"):
            audit(self.root, self.preferences, [self.workspace], 14)
        alias = self.workspace / "alias"
        alias.symlink_to(self.external, target_is_directory=True)
        with self.assertRaisesRegex(AuditFailure, "unsafe_snapshot_directory"):
            self.run_audit()
        alias.unlink()
        shared = self.external / "legacy.json"
        shared.hardlink_to(self.session)
        with self.assertRaisesRegex(AuditFailure, "unsafe_snapshot_file"):
            self.run_audit()
        shared.unlink()
        self.session.write_text('{"subscriptionAccountBinding":null,"subscriptionAccountBinding":{}}')
        with self.assertRaisesRegex(AuditFailure, "duplicate_snapshot_key"):
            self.run_audit()


if __name__ == "__main__":
    unittest.main()
