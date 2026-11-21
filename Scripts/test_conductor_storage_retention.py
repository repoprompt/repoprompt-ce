#!/usr/bin/env python3
"""Fixture-only tests for conductor's storage ownership and retention fences."""
from __future__ import annotations

import hashlib
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import conductor


def digest(path: Path) -> str:
    return hashlib.sha256(str(path).encode()).hexdigest()


class StorageFixture(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.store = self.root / "Conductor"
        self.store.mkdir(mode=0o700)
        self.repo = self.root / "current"
        self.repo.mkdir()
        for patch in (
            mock.patch.dict(os.environ, {}, clear=True),
            mock.patch.object(conductor, "default_conductor_root", return_value=self.store),
            mock.patch.object(conductor, "registered_checkout_hashes", return_value={digest(self.repo)}),
        ):
            patch.start()
            self.addCleanup(patch.stop)
        self.paths = conductor.compute_paths(self.repo)
        self.stale = conductor.now() - 2 * conductor.TERMINAL_RETENTION_SECONDS
        self.ticket = "f6982300-fedd-4126-b149-1425a1afc48e"

    def bucket(self, name: str, *, record_identity: bool = False, live_checkout: bool = False) -> Path:
        checkout = self.root / name
        if live_checkout:
            checkout.mkdir()
        bucket = self.store / digest(checkout)
        (bucket / "jobs").mkdir(mode=0o700, parents=True)
        bucket.chmod(0o700)
        (bucket / "daemon.start.lock").touch()
        if record_identity:
            conductor._atomic_write_json(bucket / "checkout.json", {"schemaVersion": 1, "checkoutPath": str(checkout)})
        return bucket

    def artifact(self, bucket: Path, kind: str, *, fresh: bool = False, receipt: bool = False) -> Path:
        path = bucket / "jobs" / f"{self.ticket}.{kind}"
        value = {"schemaVersion": 1, "ticket": self.ticket, "state": "completed"} if receipt else {}
        path.write_text(json.dumps(value))
        if not fresh:
            os.utime(path, (self.stale, self.stale))
        return path

    def test_only_owned_old_files_in_stopped_buckets_are_reclaimed(self) -> None:
        orphan = self.bucket("retired", record_identity=True)
        orphan_log = self.artifact(orphan, "log")
        sidecar = self.artifact(orphan, "cache-attempt.json")
        unknown = orphan / "jobs" / "third-party.log"
        unknown.write_text("unknown")
        legacy = self.bucket("legacy")
        legacy_log = self.artifact(legacy, "log")
        receipt = self.artifact(legacy, "timing.json", receipt=True)
        no_receipt = self.artifact(self.bucket("unproved"), "log")
        extant = self.artifact(self.bucket("extant", record_identity=True, live_checkout=True), "log")
        active_bucket = self.bucket("active", record_identity=True)
        active = self.artifact(active_bucket, "log")
        (active_bucket / "daemon.pid").write_text(str(os.getpid()))
        busy_bucket = self.bucket("startup", record_identity=True)
        busy = self.artifact(busy_bucket, "log")
        recent_bucket = self.bucket("recent", record_identity=True)
        recent = self.artifact(recent_bucket, "log", fresh=True)
        recent_receipt = self.artifact(recent_bucket, "timing.json", receipt=True)
        symlink_bucket = self.bucket("symlink", record_identity=True)
        symlink = symlink_bucket / "jobs" / f"{self.ticket}.log"
        symlink.symlink_to(unknown)
        linked_receipt = self.artifact(symlink_bucket, "timing.json", receipt=True)
        with conductor.existing_storage_lock(busy_bucket / "daemon.start.lock"):
            report = conductor.sweep_sibling_storage(self.paths, dry_run=True)
            self.assertEqual(report["files"], 4)
            self.assertTrue(all(path.exists() for path in (orphan_log, sidecar, legacy_log, receipt)))
            result = conductor.sweep_sibling_storage(self.paths, dry_run=False)
        self.assertEqual(result, report)
        self.assertTrue(all(not path.exists() for path in (orphan_log, sidecar, legacy_log, receipt)))
        self.assertTrue(all(path.exists() for path in (
            no_receipt, extant, active, busy, recent, recent_receipt, symlink, unknown, linked_receipt,
            orphan / "daemon.start.lock", orphan / "checkout.json",
        )))

    def test_state_override_does_not_discover_sibling_buckets(self) -> None:
        other = self.artifact(self.bucket("other", record_identity=True), "log")
        with mock.patch.dict(os.environ, {"REPOPROMPT_DEV_DAEMON_STATE_DIR": str(self.root / "override")}):
            result = conductor.sweep_sibling_storage(conductor.compute_paths(self.repo), dry_run=False)
        self.assertEqual(result["files"], 0)
        self.assertTrue(other.exists())

    def test_cache_limits_keep_current_checkout_preferred_and_lock_safe(self) -> None:
        root = self.store / "BuildCache"
        cache = conductor.BuildCacheManager(self.repo, store_root=root, env={
            "REPOPROMPT_DEV_BUILD_CACHE_LIMIT_BYTES": "20",
        }, startup_hygiene=False)
        cache._ensure_store_dirs()

        def seed(key: str, *, age: int = 0, checkout: str | None = None) -> Path:
            namespace = cache.store_root if checkout else root
            conductor.ensure_private_dir(namespace / "locks")
            (namespace / "locks" / f"{key}.lock").touch()
            with conductor.existing_storage_lock(namespace / "locks" / f"{key}.lock"):
                path = namespace / key / "seed"
                conductor.ensure_private_dir(path.parent)
                conductor.ensure_private_dir(path)
                (path / ".build").mkdir()
                conductor._atomic_write_json(path / ".generation.json", {"key": key, "generation": 1})
                conductor._atomic_write_json(path.parent / "meta.json", {
                    "schemaVersion": 1, "key": key, "generation": 1, "sizeBytes": 10,
                    "lastUsedAt": conductor.now() - age, "compatibility": {"checkoutPath": checkout},
                })
                return path

        legacy = seed("a" * 64)
        stale = seed("b" * 64, age=conductor.BUILD_CACHE_RETENTION_SECONDS + 10, checkout=str(self.repo))
        locked = seed("c" * 64, age=conductor.BUILD_CACHE_RETENTION_SECONDS + 10, checkout=str(self.repo))
        current = seed("d" * 64, checkout=str(self.repo))
        marker = legacy.parent / "unknown"
        marker.touch()
        with cache.key_lock("c" * 64, exclusive=False):
            report = cache.enforce_retention(dry_run=True)
            self.assertEqual(report["reclaimableBytes"], 20)
            self.assertTrue(legacy.exists())
            result = cache.enforce_retention()
        self.assertEqual(result["reclaimedBytes"], 20)
        self.assertEqual(result["remainingBytes"], 20)
        self.assertFalse(stale.exists())
        self.assertFalse(legacy.exists())
        self.assertTrue(all(path.exists() for path in (locked, current, marker, legacy.parent / "meta.json")))
        self.assertEqual(cache.enforce_retention()["reclaimedBytes"], 10)
        self.assertEqual(current.parent.parent.name, "checkout-v2")
        self.assertNotIn(current.parent.name, {child.name for child in root.iterdir()})

        interrupted = seed("e" * 64, age=conductor.BUILD_CACHE_RETENTION_SECONDS + 10, checkout=str(self.repo))
        with mock.patch.object(conductor.shutil, "rmtree", side_effect=OSError("interrupted cleanup")):
            result = cache.enforce_retention()
        self.assertEqual(result["reclaimedBytes"], 0)
        self.assertFalse(interrupted.exists())
        self.assertEqual(cache._meta("e" * 64)["generation"], 1)
        self.assertFalse(cache._validate_seed("e" * 64, cache._meta("e" * 64)))
        self.assertEqual(len(list(interrupted.parent.glob("seed.tmp-*"))), 1)

    def test_default_state_creates_a_private_parent(self) -> None:
        self.store.rmdir()
        conductor.ensure_state_dirs(self.paths)
        self.assertTrue(conductor.private_retention_directory(self.store))

    def test_build_keys_are_checkout_specific(self) -> None:
        other = self.root / "other"
        other.mkdir()
        snapshots = [conductor.BuildCacheManager(path, probe_provider=lambda: {"swift": "same"},
                                                 startup_hygiene=False).snapshot("debug", {})
                     for path in (self.repo, other)]
        self.assertEqual(snapshots[0].toolchain_signature, snapshots[1].toolchain_signature)
        self.assertNotEqual(snapshots[0].key, snapshots[1].key)

    def test_idle_daemon_schedules_once_and_retains_live_jobs(self) -> None:
        conductor.ensure_state_dirs(self.paths)
        state = conductor.DaemonState(self.paths)
        states = ("queued", "running", "completed", "completed")
        jobs = []
        for index, status in enumerate(states):
            ticket = f"{index:08d}-abcd-4126-b149-1425a1afc48e"
            path = self.paths.jobs_dir / f"{ticket}.log"
            job = conductor.Job(ticket=ticket, request_key=None, fingerprint="fp", operation="test",
                                args={}, lanes=[], timeout=None, verbose=False, env={},
                                created_at=self.stale, log_path=path, state=status,
                                finished_at=self.stale if status == "completed" else None)
            path.touch()
            os.utime(path, (self.stale, self.stale))
            state.jobs[ticket] = job
            jobs.append(job)
        jobs[2].waiter_count = 1
        with mock.patch.object(conductor.threading, "Thread") as thread:
            state.schedule_storage_maintenance()
            state.schedule_storage_maintenance()
        state._io_worker.join()
        thread.return_value.start.assert_called_once()
        self.assertEqual(set(state.jobs), {job.ticket for job in jobs[:3]})
        self.assertTrue(all(job.log_path.exists() for job in jobs[:3]))
        self.assertFalse(jobs[3].log_path.exists())
        self.assertEqual(state.status_payload()["storageRetention"]["checkoutFilesReclaimed"], 1)

    def test_job_log_rotation_preserves_head_and_latest_tail(self) -> None:
        conductor.ensure_state_dirs(self.paths)
        state = conductor.DaemonState(self.paths)
        path = self.paths.jobs_dir / f"{self.ticket}.log"
        job = conductor.Job(ticket=self.ticket, request_key=None, fingerprint="fp", operation="test",
                            args={}, lanes=[], timeout=None, verbose=False, env={},
                            created_at=conductor.now(), log_path=path)
        state.jobs[job.ticket] = job
        with mock.patch.multiple(conductor, JOB_LOG_HEAD_BYTES=16, JOB_LOG_TAIL_BYTES=16, JOB_LOG_LIMIT_BYTES=128):
            with state.condition:
                for payload in [b"H" * 16, *[b"X" * 96] * 4, b"terminal-output!"]:
                    state._queue_job_log_bytes_locked(job, payload)
            state._io_worker.join()
        self.assertLessEqual(path.stat().st_size, 128)
        self.assertTrue(path.read_bytes().startswith(b"H" * 16 + conductor.JOB_LOG_ROTATION_MARKER))
        self.assertTrue(path.read_bytes().endswith(b"terminal-output!"))
        self.assertEqual(job.log_truncation_reason, "storageLimit")


if __name__ == "__main__":
    unittest.main(verbosity=2)
