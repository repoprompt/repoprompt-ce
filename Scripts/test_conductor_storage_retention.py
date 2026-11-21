#!/usr/bin/env python3
"""Fixture-only tests for conductor's storage ownership and retention fences."""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
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
        outcome = self.artifact(orphan, "cache-outcome.json")
        unknown = orphan / "jobs" / "third-party.log"
        unknown.write_text("unknown")
        legacy = self.bucket("legacy")
        legacy_log = self.artifact(legacy, "log")
        receipt = self.artifact(legacy, "timing.json", receipt=True)
        malformed = self.bucket("malformed")
        malformed_log = self.artifact(malformed, "log")
        malformed_receipt = self.artifact(malformed, "timing.json", receipt=True)
        malformed_receipt.write_text(json.dumps({"schemaVersion": 1, "ticket": self.ticket, "state": []}))
        os.utime(malformed_receipt, (self.stale, self.stale))
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
            self.assertEqual(report["files"], 5)
            self.assertTrue(all(path.exists() for path in (orphan_log, sidecar, outcome, legacy_log, receipt)))
            result = conductor.sweep_sibling_storage(self.paths, dry_run=False)
        self.assertEqual(result, report)
        self.assertTrue(all(not path.exists() for path in (orphan_log, sidecar, outcome, legacy_log, receipt)))
        self.assertTrue(all(path.exists() for path in (
            no_receipt, extant, active, busy, recent, recent_receipt, symlink, unknown, linked_receipt,
            malformed_log, malformed_receipt, orphan / "daemon.start.lock", orphan / "checkout.json",
        )))

    def test_state_override_does_not_discover_sibling_buckets(self) -> None:
        other = self.artifact(self.bucket("other", record_identity=True), "log")
        with mock.patch.dict(os.environ, {"REPOPROMPT_DEV_DAEMON_STATE_DIR": str(self.root / "override")}):
            result = conductor.sweep_sibling_storage(conductor.compute_paths(self.repo), dry_run=False)
        self.assertEqual(result["files"], 0)
        self.assertTrue(other.exists())

    def test_new_startup_preserves_scratch_held_by_legacy_restore(self) -> None:
        cache_root = self.store / "BuildCache"
        legacy_locks = cache_root / "locks"
        conductor.ensure_private_dir(cache_root)
        conductor.ensure_private_dir(legacy_locks)
        legacy_repo_lock = legacy_locks / f"repo-{digest(self.repo)}.lock"
        legacy_repo_lock.touch(mode=0o600)
        scratch = self.repo / (".build.seed-tmp-" + "a" * 32)
        scratch.mkdir()

        with conductor.existing_storage_lock(legacy_repo_lock):
            cache = conductor.BuildCacheManager(self.repo, store_root=cache_root)
            self.assertTrue(scratch.is_dir())
        self.assertEqual(cache._sweep_repo_build_temporaries(nonblocking=True), 1)
        self.assertFalse(scratch.exists())

    def create_seed(self, namespace: Path, key: str, generation: int) -> Path:
        locks = namespace / "locks"
        conductor.ensure_private_dir(namespace)
        conductor.ensure_private_dir(locks)
        (locks / f"{key}.lock").touch(mode=0o600)
        key_dir = namespace / key
        conductor.ensure_private_dir(key_dir)
        seed = key_dir / "seed"
        conductor.ensure_private_dir(seed)
        (seed / ".build").mkdir(exist_ok=True)
        conductor._atomic_write_json(seed / ".generation.json", {"key": key, "generation": generation})
        conductor._atomic_write_json(key_dir / "meta.json", {
            "schemaVersion": 1, "key": key, "generation": generation, "sizeBytes": 10,
            "lastUsedAt": conductor.now(), "suspectCount": 0,
        })
        return seed

    def test_cold_retry_counts_only_the_originating_namespace_and_generation(self) -> None:
        cache_root = self.store / "BuildCache"
        key = "a" * 64
        legacy_seed = self.create_seed(cache_root, key, 1)
        current_seed = self.create_seed(cache_root / "checkout-v2", key, 1)
        outcome_path = self.root / "outcome.json"
        args = {
            "argv": ["fixture"], "key": key, "ticket": self.ticket, "outcomePath": str(outcome_path),
            "attemptRecordPath": str(self.root / f"{self.ticket}.cache-attempt.json"),
        }

        def retry(seed_path: Path, generation: int) -> dict:
            build = self.repo / ".build"
            build.mkdir(exist_ok=True)
            conductor._atomic_write_json(build / ".conductor-cache-provenance.json", {
                "schemaVersion": 1, "key": key, "generation": generation, "seedPath": str(seed_path),
            })
            with mock.patch.object(conductor, "_run_cache_attempt", side_effect=[(1, False), (0, False)]), \
                    mock.patch.object(conductor, "_remove_cache_build_for_retry", return_value=True):
                self.assertEqual(conductor.operation_cache_retry(self.repo, args), 0)
            return json.loads(outcome_path.read_text())

        self.assertEqual(retry(legacy_seed, 1)["suspectCount"], 1)
        self.assertEqual(conductor.read_storage_record(legacy_seed.parent / "meta.json")["suspectCount"], 1)
        self.assertEqual(conductor.read_storage_record(current_seed.parent / "meta.json")["suspectCount"], 0)
        self.create_seed(cache_root, key, 2)
        self.assertIn("suspectBookkeepingSkipped", retry(legacy_seed, 1))
        self.assertIn("suspectBookkeepingSkipped", retry(self.root / key / "seed", 1))
        self.assertEqual(conductor.read_storage_record(legacy_seed.parent / "meta.json")["suspectCount"], 0)
        self.assertTrue(legacy_seed.is_dir())
        self.assertEqual(retry(current_seed, 1)["suspectCount"], 1)
        self.assertEqual(conductor.read_storage_record(current_seed.parent / "meta.json")["suspectCount"], 1)
        self.assertEqual(conductor.read_storage_record(legacy_seed.parent / "meta.json")["suspectCount"], 0)

    def test_bad_generation_marker_does_not_stop_cache_retention(self) -> None:
        cache_root = self.store / "BuildCache"
        unreadable = self.create_seed(cache_root, "a" * 64, 1)
        readable = self.create_seed(cache_root, "b" * 64, 1)
        (unreadable / ".generation.json").write_bytes(b"\xff")

        cache = conductor.BuildCacheManager(self.repo, startup_hygiene=False)
        report = cache.enforce_retention()
        self.assertEqual(report["skippedKeys"], 1)
        self.assertTrue(unreadable.is_dir())
        self.assertFalse(readable.exists())

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
        orphan = seed("f" * 64, checkout=str(self.root / "removed-worktree"))
        redundant = seed("0" * 64, age=10, checkout=str(self.repo))
        marker = legacy.parent / "unknown"
        marker.touch()
        with cache.key_lock("c" * 64, exclusive=False):
            report = cache.enforce_retention(dry_run=True)
            self.assertEqual(report["reclaimableBytes"], 40)
            self.assertTrue(legacy.exists())
            result = cache.enforce_retention()
        self.assertEqual(result["reclaimedBytes"], 40)
        self.assertFalse(orphan.exists())
        self.assertFalse(redundant.exists())
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

    def test_cache_source_history_detects_missing_and_behind_commits(self) -> None:
        def git(*args: str) -> str:
            return subprocess.check_output(["git", *args], cwd=self.repo, text=True).strip()

        git("init", "-q")
        git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.org", "-c", "commit.gpgsign=false",
            "commit", "--quiet", "--allow-empty", "-m", "seed base")
        base = git("rev-parse", "HEAD")
        git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.org", "-c", "commit.gpgsign=false",
            "commit", "--quiet", "--allow-empty", "-m", "new head")
        head = git("rev-parse", "HEAD")
        with mock.patch.dict(os.environ, {"GIT_DIR": str(self.root / "wrong-repo"), "GIT_ALLOW_PROTOCOL": "file"}):
            self.assertEqual(conductor.BuildCacheManager._source_head(self.repo), head)
        self.assertIsNone(conductor.BuildCacheManager._source_head(self.root))

        def obsolete(path: Path, sha: str) -> bool:
            return conductor.BuildCacheManager._obsolete_source(path, sha, conductor.time.monotonic() + 5)

        self.assertFalse(obsolete(self.repo, base))
        self.assertTrue(obsolete(self.repo, "1" * 40))
        self.assertFalse(obsolete(self.repo, "unverified source"))
        self.assertFalse(obsolete(self.root, base))
        with mock.patch.object(conductor, "BUILD_CACHE_MAX_BEHIND_COMMITS", 0):
            self.assertTrue(obsolete(self.repo, base))
            self.assertFalse(obsolete(self.repo, head))

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
