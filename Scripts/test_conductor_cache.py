#!/usr/bin/env python3
"""Deterministic tests for conductor's immutable SwiftPM build-cache store."""

from __future__ import annotations

import contextlib
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import conductor  # noqa: E402


class BuildCacheTests(unittest.TestCase):
    def make_repo(self) -> tuple[tempfile.TemporaryDirectory[str], Path, Path]:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        repo = root / "repo"
        store = root / "cache"
        (repo / "Sources").mkdir(parents=True)
        (repo / "Packages" / "Local").mkdir(parents=True)
        (repo / "Package.swift").write_text("// root manifest\n", encoding="utf-8")
        (repo / "Package.resolved").write_text('{"pins":[]}\n', encoding="utf-8")
        (repo / "Packages" / "Local" / "Package.swift").write_text("// local manifest\n", encoding="utf-8")
        (repo / "Sources" / "Feature.swift").write_text("let value = 1\n", encoding="utf-8")
        return temporary, repo, store

    @staticmethod
    def probe(version: str = "Swift fixture") -> dict[str, str]:
        return {
            "swiftVersion": version,
            "sdkBuild": "26A1",
            "developerDir": "/Applications/Xcode.app/Contents/Developer",
            "architecture": "arm64",
            "destinationTriple": "arm64-apple-macosx14.0",
        }

    @staticmethod
    def clone(source: Path, destination: Path) -> bool:
        shutil.copytree(source, destination)
        return True

    def manager(self, repo: Path, store: Path, **kwargs: object) -> conductor.BuildCacheManager:
        return conductor.BuildCacheManager(
            repo,
            store_root=store,
            probe_provider=kwargs.pop("probe_provider", lambda: self.probe()),
            clone_runner=kwargs.pop("clone_runner", self.clone),
            **kwargs,
        )

    @staticmethod
    def create_build(repo: Path, content: bytes = b"artifact") -> None:
        build = repo / ".build"
        build.mkdir()
        (build / "artifact.bin").write_bytes(content)
        (build / "xcode").mkdir()
        (build / "xcode" / "mutable").write_text("discard", encoding="utf-8")
        (build / "compile.log").write_text("discard", encoding="utf-8")
        module_cache = build / "arm64-apple-macosx" / "debug" / "ModuleCache"
        module_cache.mkdir(parents=True)
        (module_cache / "path-bound.pcm").write_bytes(b"discard")

    def publish_seed(self, manager: conductor.BuildCacheManager, env: dict[str, str] | None = None) -> tuple[conductor.BuildCacheContext, dict]:
        context = manager.prepare("build", {}, env or {})
        self.assertIsNotNone(context)
        assert context is not None
        result = manager.publish(context)
        self.assertEqual(result["state"], "published")
        return context, result

    def test_key_sensitivity_and_source_exclusion(self) -> None:
        temporary, repo, store = self.make_repo()
        self.addCleanup(temporary.cleanup)
        probe_value = [self.probe()]
        manager = self.manager(repo, store, probe_provider=lambda: dict(probe_value[0]))

        baseline = manager.snapshot("debug", {})
        (repo / "Sources" / "Feature.swift").write_text("let value = 2\n", encoding="utf-8")
        self.assertEqual(manager.snapshot("debug", {}).key, baseline.key)
        self.assertNotEqual(manager.snapshot("release", {}).key, baseline.key)
        self.assertNotEqual(manager.snapshot("debug", {"REPOPROMPT_ENABLE_SENTRY": "1"}).key, baseline.key)
        self.assertNotEqual(manager.snapshot("debug", {"CC": "/usr/bin/clang-fixture"}).key, baseline.key)
        self.assertNotEqual(manager.snapshot("debug", {"CXX": "/usr/bin/clang++-fixture"}).key, baseline.key)
        (repo / "Package.swift").write_text("// changed manifest\n", encoding="utf-8")
        self.assertNotEqual(manager.snapshot("debug", {}).key, baseline.key)
        (repo / "Package.swift").write_text("// root manifest\n", encoding="utf-8")
        probe_value[0] = self.probe("Swift fixture changed")
        self.assertNotEqual(manager.snapshot("debug", {}).key, baseline.key)

    def test_atomic_generation_publication_rejects_stale_publisher(self) -> None:
        temporary, repo, store = self.make_repo()
        self.addCleanup(temporary.cleanup)
        self.create_build(repo)
        manager = self.manager(repo, store)
        first = manager.prepare("build", {}, {})
        stale = manager.prepare("build", {}, {})
        assert first is not None and stale is not None

        published = manager.publish(first)
        rejected = manager.publish(stale)
        meta = json.loads((store / first.snapshot.key / "meta.json").read_text(encoding="utf-8"))
        marker = json.loads((store / first.snapshot.key / "seed" / ".generation.json").read_text(encoding="utf-8"))

        self.assertEqual(published["generation"], 1)
        self.assertEqual(rejected["state"], "publicationSkipped")
        self.assertEqual(rejected["reason"], "newer generation already published")
        self.assertEqual(meta["generation"], marker["generation"])
        self.assertFalse((store / first.snapshot.key / "seed" / ".build" / "xcode").exists())
        self.assertFalse((store / first.snapshot.key / "seed" / ".build" / "compile.log").exists())
        self.assertFalse(
            (store / first.snapshot.key / "seed" / ".build" / "arm64-apple-macosx" / "debug" / "ModuleCache").exists()
        )

    def test_publish_stage_exceptions_clean_temporary_seed_lifecycle(self) -> None:
        stages = ("sanitize", "marker", "du", "swap", "meta")
        for stage in stages:
            with self.subTest(stage=stage):
                temporary, repo, store = self.make_repo()
                try:
                    self.create_build(repo)
                    manager = self.manager(repo, store)
                    context = manager.prepare("build", {}, {})
                    assert context is not None
                    real_atomic_write = conductor._atomic_write_json
                    real_replace = conductor.os.replace

                    def atomic_write(path: Path, payload: dict) -> None:
                        if stage == "marker" and path.name == ".generation.json":
                            raise OSError("marker fixture")
                        if stage == "meta" and path.name == "meta.json":
                            raise OSError("meta fixture")
                        real_atomic_write(path, payload)

                    def replace(source: Path, destination: Path) -> None:
                        if stage == "swap" and source.name.startswith("seed.tmp-") and destination.name == "seed":
                            raise OSError("swap fixture")
                        real_replace(source, destination)

                    sanitize = mock.patch.object(
                        manager,
                        "_sanitize_seed",
                        side_effect=OSError("sanitize fixture") if stage == "sanitize" else None,
                        wraps=manager._sanitize_seed if stage != "sanitize" else None,
                    )
                    disk_usage = mock.patch.object(
                        manager,
                        "_disk_usage_bytes",
                        side_effect=OSError("du fixture") if stage == "du" else None,
                        wraps=manager._disk_usage_bytes if stage != "du" else None,
                    )
                    with sanitize, disk_usage, mock.patch.object(conductor, "_atomic_write_json", side_effect=atomic_write), mock.patch.object(
                        conductor.os, "replace", side_effect=replace
                    ), self.assertRaises(OSError):
                        manager.publish(context)

                    key_dir = store / context.snapshot.key
                    self.assertEqual(list(key_dir.glob("seed.tmp-*")), [])
                    self.assertEqual(list(key_dir.glob("seed.previous-*")), [])
                    self.assertFalse((key_dir / "seed").exists())
                finally:
                    temporary.cleanup()

    def test_failed_replacement_metadata_write_restores_previous_generation(self) -> None:
        temporary, repo, store = self.make_repo()
        self.addCleanup(temporary.cleanup)
        self.create_build(repo)
        manager = self.manager(repo, store)
        first_context, _ = self.publish_seed(manager)
        key_dir = store / first_context.snapshot.key
        first_artifact = (key_dir / "seed" / ".build" / "artifact.bin").read_bytes()
        meta_path = key_dir / "meta.json"
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        meta["publishedAt"] = 0
        conductor._atomic_write_json(meta_path, meta)
        (repo / ".build" / "artifact.bin").write_bytes(b"replacement")
        replacement = manager.prepare("build", {}, {})
        assert replacement is not None
        real_atomic_write = conductor._atomic_write_json

        def atomic_write(path: Path, payload: dict) -> None:
            if path.name == "meta.json" and payload.get("generation") == 2:
                raise OSError("replacement meta fixture")
            real_atomic_write(path, payload)

        with mock.patch.object(conductor, "_atomic_write_json", side_effect=atomic_write), self.assertRaises(OSError):
            manager.publish(replacement)

        marker = json.loads((key_dir / "seed" / ".generation.json").read_text(encoding="utf-8"))
        persisted_meta = json.loads(meta_path.read_text(encoding="utf-8"))
        self.assertEqual(marker["generation"], 1)
        self.assertEqual(persisted_meta["generation"], 1)
        self.assertEqual((key_dir / "seed" / ".build" / "artifact.bin").read_bytes(), first_artifact)
        self.assertEqual(list(key_dir.glob("seed.tmp-*")), [])
        self.assertEqual(list(key_dir.glob("seed.previous-*")), [])

    def test_post_replace_directory_fsync_failure_keeps_committed_seed_and_metadata_generation(self) -> None:
        temporary, repo, store = self.make_repo()
        self.addCleanup(temporary.cleanup)
        self.create_build(repo)
        manager = self.manager(repo, store)
        first_context, _ = self.publish_seed(manager)
        key_dir = store / first_context.snapshot.key
        meta_path = key_dir / "meta.json"
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        meta["publishedAt"] = 0
        conductor._atomic_write_json(meta_path, meta)
        (repo / ".build" / "artifact.bin").write_bytes(b"replacement")
        replacement = manager.prepare("build", {}, {})
        assert replacement is not None
        real_open = conductor.os.open

        def open_file(path: object, flags: int, mode: int = 0o777, *args: object, **kwargs: object) -> int:
            if not kwargs.get("dir_fd") and Path(path) == key_dir and flags == os.O_RDONLY:
                raise OSError("directory fsync open fixture")
            return real_open(path, flags, mode, *args, **kwargs)

        with mock.patch.object(conductor.os, "open", side_effect=open_file):
            published = manager.publish(replacement)

        marker = json.loads((key_dir / "seed" / ".generation.json").read_text(encoding="utf-8"))
        persisted_meta = json.loads(meta_path.read_text(encoding="utf-8"))
        self.assertEqual(published["generation"], 2)
        self.assertEqual(marker["generation"], 2)
        self.assertEqual(persisted_meta["generation"], 2)
        self.assertEqual((key_dir / "seed" / ".build" / "artifact.bin").read_bytes(), b"replacement")
        self.assertEqual(list(key_dir.glob("seed.previous-*")), [])

    def test_store_hygiene_sweeps_startup_and_maintenance_but_skips_locked_keys(self) -> None:
        temporary, repo, store = self.make_repo()
        self.addCleanup(temporary.cleanup)
        first_key = "a" * 64
        first_dir = store / first_key
        first_dir.mkdir(parents=True)
        (first_dir / f"seed.tmp-{'1' * 32}").mkdir()
        (first_dir / f"seed.previous-{'2' * 32}").mkdir()

        manager = self.manager(repo, store)
        self.assertEqual(list(first_dir.glob("seed.tmp-*")), [])
        self.assertEqual(list(first_dir.glob("seed.previous-*")), [])

        (first_dir / f"seed.tmp-{'3' * 32}").mkdir()
        maintenance = manager.enforce_retention("toolchain")
        self.assertEqual(maintenance["hygiene"]["removed"], 1)

        locked_key = "b" * 64
        locked_dir = store / locked_key
        locked_dir.mkdir()
        locked_temp = locked_dir / f"seed.tmp-{'4' * 32}"
        locked_temp.mkdir()
        real_key_lock = manager.key_lock

        @contextlib.contextmanager
        def key_lock(key: str, *, exclusive: bool, nonblocking: bool = False):
            if key == locked_key:
                raise BlockingIOError()
            with real_key_lock(key, exclusive=exclusive, nonblocking=nonblocking) as lock_file:
                yield lock_file

        with mock.patch.object(manager, "key_lock", side_effect=key_lock):
            result = manager._sweep_stranded_store_temporaries()

        self.assertEqual(result["skippedLockedKeys"], 1)
        self.assertTrue(locked_temp.exists())

    def test_startup_hygiene_failure_is_advisory_once_prepare_recovers(self) -> None:
        temporary, repo, store = self.make_repo()
        self.addCleanup(temporary.cleanup)
        with mock.patch.object(
            conductor.BuildCacheManager,
            "_sweep_stranded_store_temporaries",
            side_effect=OSError("startup hygiene fixture"),
        ):
            manager = self.manager(repo, store)

        recovered = manager.prepare("build", {}, {})
        assert recovered is not None
        self.assertEqual(recovered.status["state"], "coldMiss")
        self.assertIn("startup hygiene fixture", recovered.status["startupAdvisoryFailure"])

        subsequent = manager.prepare("build", {}, {})
        assert subsequent is not None
        self.assertNotIn("startupAdvisoryFailure", subsequent.status)

    def test_store_hygiene_restores_valid_previous_generation_when_seed_is_missing(self) -> None:
        temporary, repo, store = self.make_repo()
        self.addCleanup(temporary.cleanup)
        key = "c" * 64
        key_dir = store / key
        previous = key_dir / f"seed.previous-{'5' * 32}"
        (previous / ".build").mkdir(parents=True)
        (previous / ".generation.json").write_text(
            json.dumps({"key": key, "generation": 7}), encoding="utf-8"
        )
        (key_dir / "meta.json").write_text(
            json.dumps({"key": key, "generation": 7}), encoding="utf-8"
        )

        self.manager(repo, store)

        self.assertTrue((key_dir / "seed" / ".build").is_dir())
        self.assertFalse(previous.exists())

    def test_prepare_sweeps_only_verified_repo_temporaries_at_start_and_prepare_boundaries(self) -> None:
        temporary, repo, store = self.make_repo()
        self.addCleanup(temporary.cleanup)
        startup_temp = repo / f".build.seed-tmp-{'6' * 32}"
        invalid_name = repo / ".build.seed-tmp-not-cache-owned"
        startup_temp.mkdir()
        invalid_name.mkdir()

        manager = self.manager(repo, store)
        self.assertFalse(startup_temp.exists())
        self.assertTrue(invalid_name.exists())

        prepare_temp = repo / f".build.seed-tmp-{'7' * 32}"
        prepare_temp.mkdir()
        context = manager.prepare("build", {}, {})

        self.assertIsNotNone(context)
        self.assertFalse(prepare_temp.exists())
        self.assertTrue(invalid_name.exists())

    def test_prepare_filesystem_failure_is_advisory_and_preserves_warm_build_provenance(self) -> None:
        temporary, repo, store = self.make_repo()
        self.addCleanup(temporary.cleanup)
        self.create_build(repo)
        provenance = repo / ".build" / ".conductor-cache-provenance.json"
        provenance.write_text('{"fixture":"preserve"}', encoding="utf-8")
        artifact_before = (repo / ".build" / "artifact.bin").read_bytes()
        manager = self.manager(repo, store)

        with mock.patch.object(manager, "_remove_repo_build_temporaries_locked", side_effect=OSError("filesystem fixture")):
            context = manager.prepare("build", {}, {})

        assert context is not None
        self.assertFalse(context.seeded)
        self.assertEqual(context.status["state"], "warmLocalAdvisory")
        self.assertIn("filesystem fixture", context.status["advisoryFailure"])
        self.assertEqual((repo / ".build" / "artifact.bin").read_bytes(), artifact_before)
        self.assertEqual(provenance.read_text(encoding="utf-8"), '{"fixture":"preserve"}')

    def test_prepare_store_and_clone_failures_degrade_cold_and_clean_owned_temporary(self) -> None:
        temporary, repo, store = self.make_repo()
        self.addCleanup(temporary.cleanup)
        manager = self.manager(repo, store)
        with mock.patch.object(manager, "_ensure_store_dirs", side_effect=OSError("store fixture")):
            unavailable = manager.prepare("build", {}, {})
        assert unavailable is not None
        self.assertEqual(unavailable.status["state"], "cacheAdvisoryCold")
        self.assertFalse((repo / ".build").exists())

        self.create_build(repo)
        context, _ = self.publish_seed(manager)
        shutil.rmtree(repo / ".build")

        def failing_clone(_source: Path, destination: Path) -> bool:
            destination.mkdir(parents=True)
            raise OSError("clone fixture")

        failing = self.manager(repo, store, clone_runner=failing_clone)
        cold = failing.prepare("build", {}, {})
        assert cold is not None
        self.assertEqual(cold.status["state"], "cacheAdvisoryCold")
        self.assertIn("clone fixture", cold.status["advisoryFailure"])
        self.assertFalse((repo / ".build").exists())
        self.assertEqual(list(repo.glob(".build.seed-tmp-*")), [])
        self.assertEqual(cold.snapshot.key, context.snapshot.key)

    def test_native_clone_uses_supported_ditto_with_entry_bounded_deadline(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source"
            destination = root / "destination"
            (source / "nested").mkdir(parents=True)
            (source / "artifact").write_bytes(b"artifact")
            (source / "nested" / "object").write_bytes(b"object")
            deadline = conductor.BuildCacheManager._clone_deadline_seconds(source)
            self.assertGreater(deadline, conductor.BUILD_CACHE_CLONE_MIN_SECONDS)
            self.assertLessEqual(deadline, conductor.BUILD_CACHE_CLONE_MAX_SECONDS)

            def fake_run(argv: list[str], **kwargs: object) -> mock.Mock:
                self.assertEqual(
                    argv,
                    [
                        "/usr/bin/ditto",
                        "--clone",
                        "--norsrc",
                        "--noextattr",
                        "--noqtn",
                        "--noacl",
                        str(source),
                        str(destination),
                    ],
                )
                self.assertEqual(kwargs["timeout"], 123.0)
                destination.mkdir()
                return mock.Mock(returncode=0)

            with mock.patch.object(conductor.BuildCacheManager, "_clone_deadline_seconds", return_value=123.0), mock.patch.object(
                conductor.subprocess, "run", side_effect=fake_run
            ):
                self.assertTrue(conductor.BuildCacheManager._clone_cow(source, destination))

    def test_tree_maintenance_deadlines_scale_by_entries_and_size_with_bounded_limits(self) -> None:
        minimum = conductor.BuildCacheManager._tree_deadline_for_work(0, 0)
        scaled = conductor.BuildCacheManager._tree_deadline_for_work(100, 2 * 1024**3)
        maximum = conductor.BuildCacheManager._tree_deadline_for_work(10**9, 10**15)

        self.assertEqual(minimum, conductor.BUILD_CACHE_CLONE_MIN_SECONDS)
        self.assertGreater(scaled, minimum)
        self.assertLess(scaled, conductor.BUILD_CACHE_CLONE_MAX_SECONDS)
        self.assertEqual(maximum, conductor.BUILD_CACHE_CLONE_MAX_SECONDS)

        with tempfile.TemporaryDirectory() as tmp:
            build = Path(tmp) / ".build"
            build.mkdir()
            empty_deadline = conductor.BuildCacheManager._tree_deadline_seconds(build)
            artifact = build / "artifact"
            artifact.touch()
            entry_deadline = conductor.BuildCacheManager._tree_deadline_seconds(build)
            artifact.write_bytes(b"x" * 1024 * 1024)
            sized_deadline = conductor.BuildCacheManager._tree_deadline_seconds(build)
            self.assertGreater(entry_deadline, empty_deadline)
            self.assertGreater(sized_deadline, entry_deadline)
            calls: list[float] = []

            def fake_run(argv: list[str], **kwargs: object) -> mock.Mock:
                calls.append(float(kwargs["timeout"]))
                stdout = "4\tfixture\n" if argv[0] == "/usr/bin/du" else ""
                return mock.Mock(returncode=0, stdout=stdout)

            with mock.patch.object(
                conductor.BuildCacheManager,
                "_tree_deadline_seconds",
                return_value=137.0,
            ), mock.patch.object(conductor.subprocess, "run", side_effect=fake_run):
                conductor.BuildCacheManager._sanitize_seed(build)
                self.assertEqual(conductor.BuildCacheManager._disk_usage_bytes(build), 4096)

        self.assertEqual(calls, [137.0, 137.0, 137.0])

    def test_status_is_read_only_and_does_not_run_startup_repair(self) -> None:
        temporary, repo, store = self.make_repo()
        self.addCleanup(temporary.cleanup)
        manager = self.manager(repo, store, startup_hygiene=False)

        missing = manager.status()
        self.assertTrue(missing["readOnly"])
        self.assertEqual(missing["entryCount"], 0)
        self.assertFalse(store.exists())

        key = "d" * 64
        stranded = store / key / f"seed.tmp-{'8' * 32}"
        stranded.mkdir(parents=True)
        observed = manager.status()

        self.assertTrue(observed["readOnly"])
        self.assertEqual(observed["entryCount"], 1)
        self.assertTrue(stranded.exists())
        self.assertFalse((store / "locks").exists())

    def test_private_clone_is_atomic_and_clone_failure_falls_back_cold(self) -> None:
        temporary, repo, store = self.make_repo()
        self.addCleanup(temporary.cleanup)
        self.create_build(repo)
        manager = self.manager(repo, store)
        context, _published = self.publish_seed(manager)
        shutil.rmtree(repo / ".build")

        seeded = manager.prepare("build", {}, {})
        assert seeded is not None
        self.assertTrue(seeded.seeded)
        self.assertEqual(seeded.status["state"], "seeded")
        self.assertFalse((repo / ".build").is_symlink())
        provenance = json.loads((repo / ".build" / ".conductor-cache-provenance.json").read_text(encoding="utf-8"))
        self.assertEqual(provenance["key"], context.snapshot.key)
        (repo / ".build" / "artifact.bin").write_bytes(b"worktree mutation")
        self.assertEqual((store / context.snapshot.key / "seed" / ".build" / "artifact.bin").read_bytes(), b"artifact")

        shutil.rmtree(repo / ".build")
        failing = self.manager(repo, store, clone_runner=lambda _source, _destination: False)
        cold = failing.prepare("build", {}, {})
        assert cold is not None
        self.assertFalse(cold.seeded)
        self.assertEqual(cold.status["state"], "cloneFailedCold")
        self.assertFalse((repo / ".build").exists())
        self.assertEqual(list(repo.glob(".build.seed-tmp-*")), [])

    def test_corrupt_seed_is_quarantined_and_second_confirmed_failure_removes_suspect(self) -> None:
        temporary, repo, store = self.make_repo()
        self.addCleanup(temporary.cleanup)
        self.create_build(repo)
        manager = self.manager(repo, store)
        context, _published = self.publish_seed(manager)
        key = context.snapshot.key
        shutil.rmtree(repo / ".build")
        (store / key / "seed" / ".generation.json").write_text('{"key":"wrong","generation":1}', encoding="utf-8")

        cold = manager.prepare("build", {}, {})
        assert cold is not None
        self.assertEqual(cold.status["state"], "corruptSeedCold")
        self.assertFalse((store / key / "seed").exists())

        self.create_build(repo)
        replacement = manager.prepare("build", {}, {})
        assert replacement is not None
        manager.publish(replacement)
        first = manager.confirm_seeded_failure(key)
        second = manager.confirm_seeded_failure(key)
        self.assertEqual(first, {"suspectCount": 1, "quarantined": False})
        self.assertEqual(second, {"suspectCount": 2, "quarantined": True})
        self.assertFalse((store / key / "seed").exists())

    def test_retention_prefers_toolchain_mismatch_and_skips_locked_key(self) -> None:
        temporary, repo, store = self.make_repo()
        self.addCleanup(temporary.cleanup)
        self.create_build(repo, b"a" * 128)
        manager = self.manager(repo, store)
        first, _ = self.publish_seed(manager, {})
        shutil.rmtree(repo / ".build")
        self.create_build(repo, b"b" * 128)
        second_context = manager.prepare("build", {}, {"REPOPROMPT_ENABLE_SENTRY": "1"})
        assert second_context is not None
        manager.publish(second_context)
        first_meta_path = store / first.snapshot.key / "meta.json"
        first_meta = json.loads(first_meta_path.read_text(encoding="utf-8"))
        first_meta["toolchainSignature"] = "old-toolchain"
        conductor._atomic_write_json(first_meta_path, first_meta)
        manager.env["REPOPROMPT_DEV_BUILD_CACHE_LIMIT_BYTES"] = "0"

        with manager.key_lock(second_context.snapshot.key, exclusive=False):
            result = manager.enforce_retention(second_context.snapshot.toolchain_signature)

        self.assertIn(first.snapshot.key, result["evictedKeys"])
        self.assertNotIn(second_context.snapshot.key, result["evictedKeys"])
        self.assertTrue((store / second_context.snapshot.key).exists())

    def test_successful_job_publishes_only_after_global_heavy_slot_release(self) -> None:
        temporary, repo, store = self.make_repo()
        self.addCleanup(temporary.cleanup)
        jobs = repo / "jobs"
        jobs.mkdir()
        paths = conductor.Paths(
            repo_root=repo,
            repo_hash="cache-order",
            state_dir=repo,
            socket_path=repo / "daemon.sock",
            pid_path=repo / "daemon.pid",
            lock_path=repo / "daemon.lock",
            jobs_dir=jobs,
            daemon_log_path=repo / "daemon.log",
            daemon_meta_path=repo / "daemon.json",
            running_processes_path=repo / "running.json",
        )
        state = conductor.DaemonState(paths)
        self.addCleanup(state._output_pump.close)
        self.addCleanup(state._io_worker.join)
        job = conductor.Job(
            ticket="cache-order",
            request_key=None,
            fingerprint="fixture",
            operation="build",
            args={},
            lanes=["build"],
            timeout=None,
            verbose=False,
            env={},
            created_at=conductor.now(),
            log_path=jobs / "cache-order.log",
            state="running",
        )
        state.jobs[job.ticket] = job
        state.active_lanes["build"] = job.ticket
        snapshot = conductor.BuildCacheSnapshot("a" * 64, {"configuration": "debug"}, "toolchain")
        context = conductor.BuildCacheContext(snapshot, 0, True, {"state": "seeded", "key": snapshot.key})
        released = []
        startup_events: list[str] = []
        original_write = os.write

        def tracked_write(fd: int, payload: bytes) -> int:
            if payload == b"1":
                startup_events.append("wrapper-release")
                return 1
            return original_write(fd, payload)

        class FakeCache:
            def prepare(self, *_args: object) -> conductor.BuildCacheContext:
                return context

            def publish(self, _context: conductor.BuildCacheContext) -> dict:
                self_test.assertEqual(released, ["lease"])
                self_test.assertEqual(job.global_heavy_admission_state, "released")
                self_test.assertEqual(job.state, "running")
                self_test.assertEqual(job.phase, "publishingCache")
                self_test.assertIsNone(job.finished_at)
                self_test.assertEqual(state.active_lanes["build"], job.ticket)
                mutator_lanes = state.registry.prepare({"operation": "run", "args": {}})[1]
                waiting = conductor.Job(
                    ticket="waiting-mutator",
                    request_key=None,
                    fingerprint="fixture-waiting",
                    operation="run",
                    args={},
                    lanes=mutator_lanes,
                    timeout=None,
                    verbose=False,
                    env={},
                    created_at=conductor.now(),
                    log_path=jobs / "waiting-mutator.log",
                )
                state.jobs[waiting.ticket] = waiting
                state.queue.append(waiting.ticket)
                blockers = state._blocked_by_locked(waiting)
                self_test.assertEqual(blockers[0]["ticket"], job.ticket)
                self_test.assertEqual(blockers[0]["conflictingLanes"], ["build"])
                canceled = state.job_cancel(job.ticket, None)
                self_test.assertTrue(canceled["cancellationIgnored"])
                self_test.assertIn("non-abortable", canceled["cancellationIgnoredReason"])
                self_test.assertFalse(job.cancel_requested)
                self_test.assertEqual(job.phase, "publishingCache")
                return {"state": "published", "generation": 1}

        self_test = self
        fake_process = mock.Mock()
        fake_process.pid = os.getpid()
        fake_process.wait.return_value = 0
        with mock.patch.object(state.registry, "prepare", return_value=(["/usr/bin/true"], ["build"], repo, {}, 11.0)), mock.patch.object(
            state, "_build_cache_manager", return_value=FakeCache()
        ), mock.patch.object(
            conductor.BuildCacheManager, "_tree_deadline_seconds", return_value=29.0
        ), mock.patch.object(state, "_acquire_global_heavy_slot", return_value="lease"), mock.patch.object(
            state, "_release_global_heavy_slot", side_effect=lambda lease: released.append(lease)
        ), mock.patch.object(conductor.subprocess, "Popen", return_value=fake_process), mock.patch.object(
            conductor, "process_table_snapshot", return_value={}
        ), mock.patch.object(conductor, "process_start_token", return_value="fixture"), mock.patch.object(
            state,
            "_write_running_processes_durable",
            side_effect=lambda: startup_events.append("durable-running-registry"),
        ), mock.patch.object(conductor.os, "write", side_effect=tracked_write), mock.patch.object(
            state, "_schedule_locked"
        ), mock.patch.object(state, "_refresh_output_summary"):
            state._run_job(job.ticket)

        self.assertEqual(job.state, "completed")
        self.assertEqual(startup_events, ["durable-running-registry", "wrapper-release"])
        fake_process.wait.assert_called_once_with(
            timeout=conductor.BuildCacheManager.retry_job_timeout(11.0, 29.0)
        )
        self.assertEqual(job.build_cache["attemptTimeoutSeconds"], 11.0)
        self.assertEqual(job.build_cache["cleanupTimeoutSeconds"], 29.0)
        self.assertEqual(
            job.build_cache["retryEnvelopeTimeoutSeconds"],
            2 * 11.0 + 29.0 + conductor.BUILD_CACHE_RETRY_OVERHEAD_SECONDS,
        )
        self.assertEqual(job.build_cache["publication"]["state"], "published")
        self.assertEqual(
            job.result_summary,
            "completed successfully; cancellation ignored during non-abortable cache publication",
        )
        self.assertTrue(job.to_payload()["cancellationIgnored"])
        self.assertEqual(state.status_payload()["cacheWriteLane"]["activeTicket"], None)

    def test_cache_retry_wrapper_gate_eof_prevents_any_attempt(self) -> None:
        read_fd, write_fd = os.pipe()
        os.close(write_fd)
        with mock.patch.dict(
            os.environ,
            {"REPOPROMPT_CONDUCTOR_CACHE_WRAPPER_GATE_FD": str(read_fd)},
        ), mock.patch.object(conductor, "_run_cache_attempt") as attempt, self.assertRaises(conductor.ConductorError):
            conductor.operation_cache_retry(Path("/tmp/repo"), {})

        attempt.assert_not_called()

    def test_cache_attempt_gate_eof_never_execs_the_real_build(self) -> None:
        read_fd, write_fd = os.pipe()
        os.close(write_fd)
        with mock.patch.object(conductor.os, "execvpe") as execvpe:
            code = conductor.run_cache_attempt_gate(read_fd, json.dumps(["swift", "build"]))

        self.assertEqual(code, 125)
        execvpe.assert_not_called()

    def test_timed_out_cache_attempt_escalates_and_reaps_its_process_group(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        attempt_record = Path(temporary.name) / "cache-attempt.cache-attempt.json"
        process = mock.Mock(pid=4242)
        process.wait.side_effect = [
            subprocess.TimeoutExpired(["swift", "build"], 7.0),
            subprocess.TimeoutExpired(["swift", "build"], conductor.TERMINATE_GRACE_SECONDS),
            -signal.SIGKILL,
        ]
        process.poll.return_value = -signal.SIGKILL

        events: list[str] = []

        def publish_record(path: Path, payload: dict) -> None:
            self.assertEqual(path, attempt_record)
            self.assertEqual(payload["wrapperStartToken"], "wrapper-start")
            self.assertEqual(payload["attemptStartToken"], "attempt-start")
            events.append("record")

        def release_gate(_fd: int, payload: bytes) -> int:
            self.assertEqual(payload, b"1")
            events.append("release")
            return 1

        with mock.patch.object(conductor.subprocess, "Popen", return_value=process) as popen, mock.patch.object(
            conductor, "process_start_token", side_effect=lambda pid: "attempt-start" if pid == 4242 else "wrapper-start"
        ), mock.patch.object(conductor.os, "getpgid", return_value=4242), mock.patch.object(
            conductor, "_atomic_write_json", side_effect=publish_record
        ), mock.patch.object(conductor, "_durable_unlink") as durable_unlink, mock.patch.object(
            conductor.os, "write", side_effect=release_gate
        ), mock.patch.object(conductor.os, "killpg") as killpg:
            result = conductor._run_cache_attempt(
                ["swift", "build"],
                Path("/tmp/repo"),
                7.0,
                attempt_record,
                "cache-attempt",
            )

        self.assertEqual(result, (124, True))
        self.assertTrue(popen.call_args.kwargs["start_new_session"])
        self.assertIn("__cache_attempt_gate", popen.call_args.args[0])
        self.assertEqual(events, ["record", "release"])
        durable_unlink.assert_called_once_with(attempt_record)
        self.assertEqual(
            process.wait.call_args_list,
            [
                mock.call(timeout=7.0),
                mock.call(timeout=conductor.TERMINATE_GRACE_SECONDS),
                mock.call(timeout=conductor.KILL_GRACE_SECONDS),
            ],
        )
        self.assertEqual(
            killpg.call_args_list,
            [mock.call(4242, signal.SIGTERM), mock.call(4242, signal.SIGKILL)],
        )

    def test_inconclusive_attempt_reap_preserves_durable_identity_record(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        attempt_record = Path(temporary.name) / "inconclusive.cache-attempt.json"
        process = mock.Mock(pid=5151)
        process.wait.side_effect = [
            subprocess.TimeoutExpired(["swift", "build"], 3.0),
            subprocess.TimeoutExpired(["swift", "build"], conductor.TERMINATE_GRACE_SECONDS),
            subprocess.TimeoutExpired(["swift", "build"], conductor.KILL_GRACE_SECONDS),
        ]
        process.poll.return_value = None

        original_write = os.write

        def tracked_write(fd: int, payload: bytes) -> int:
            if payload == b"1":
                return 1
            return original_write(fd, payload)

        with mock.patch.object(conductor.subprocess, "Popen", return_value=process), mock.patch.object(
            conductor, "process_start_token", side_effect=lambda pid: "attempt-start" if pid == 5151 else "wrapper-start"
        ), mock.patch.object(conductor.os, "getpgid", return_value=5151), mock.patch.object(
            conductor.os, "write", side_effect=tracked_write
        ), mock.patch.object(conductor.os, "killpg"):
            with self.assertRaisesRegex(conductor.ConductorError, "did not exit"):
                conductor._run_cache_attempt(
                    ["swift", "build"],
                    Path("/tmp/repo"),
                    3.0,
                    attempt_record,
                    "inconclusive",
                )

        payload = json.loads(attempt_record.read_text(encoding="utf-8"))
        self.assertEqual(payload["attemptPID"], 5151)
        self.assertEqual(payload["attemptStartToken"], "attempt-start")

    def test_terminal_cache_attempt_timeout_projects_to_job_contract(self) -> None:
        def make_job(ticket: str) -> conductor.Job:
            return conductor.Job(
                ticket=ticket,
                request_key=None,
                fingerprint="fixture",
                operation="build",
                args={},
                lanes=["build"],
                timeout=17.0,
                verbose=False,
                env={},
                created_at=conductor.now(),
                log_path=Path("/tmp") / f"{ticket}.log",
                state="failed",
                exit_code=124,
            )

        seeded = make_job("seeded-timeout")
        conductor.DaemonState._apply_cache_retry_outcome_locked(
            seeded,
            {
                "attemptTimeoutSeconds": 17.0,
                "seededTimedOut": True,
                "coldRetryAttempted": False,
            },
        )
        self.assertTrue(seeded.to_payload()["timedOut"])
        self.assertEqual(seeded.error, "seeded cache build attempt timed out after 17.0s")

        cold = make_job("cold-timeout")
        conductor.DaemonState._apply_cache_retry_outcome_locked(
            cold,
            {
                "attemptTimeoutSeconds": 17.0,
                "seededTimedOut": False,
                "coldRetryAttempted": True,
                "coldTimedOut": True,
            },
        )
        self.assertTrue(cold.to_payload()["timedOut"])
        self.assertEqual(cold.error, "cold recovery cache build attempt timed out after 17.0s")

    def test_seeded_failure_retries_cold_once_and_records_suspect(self) -> None:
        temporary, repo, store = self.make_repo()
        self.addCleanup(temporary.cleanup)
        self.create_build(repo)
        manager = self.manager(repo, store)
        context, _ = self.publish_seed(manager)
        key = context.snapshot.key
        (repo / ".build" / ".conductor-cache-provenance.json").write_text(
            json.dumps({"key": key}), encoding="utf-8"
        )
        ticket = "seeded-retry"
        outcome = repo / f"{ticket}.cache-outcome.json"
        attempt_record = repo / f"{ticket}.cache-attempt.json"
        with mock.patch.dict(os.environ, {"REPOPROMPT_DEV_BUILD_CACHE_DIR": str(store)}), mock.patch.object(
            conductor,
            "_run_cache_attempt",
            side_effect=[(1, False), (0, False)],
        ) as run:
            code = conductor.operation_cache_retry(
                repo,
                {
                    "argv": ["swift", "build"],
                    "key": key,
                    "outcomePath": str(outcome),
                    "attemptTimeout": 17.0,
                    "cleanupTimeout": 31.0,
                    "attemptRecordPath": str(attempt_record),
                    "ticket": ticket,
                },
            )

        payload = json.loads(outcome.read_text(encoding="utf-8"))
        self.assertEqual(code, 0)
        self.assertEqual(run.call_count, 2)
        self.assertEqual([call.args[2] for call in run.call_args_list], [17.0, 17.0])
        self.assertEqual([call.args[3] for call in run.call_args_list], [attempt_record, attempt_record])
        self.assertEqual([call.args[4] for call in run.call_args_list], [ticket, ticket])
        self.assertEqual(payload["attemptTimeoutSeconds"], 17.0)
        self.assertEqual(payload["cleanupTimeoutSeconds"], 31.0)
        self.assertFalse(payload["seededTimedOut"])
        self.assertFalse(payload["coldTimedOut"])
        self.assertTrue(payload["coldRetryAttempted"])
        self.assertTrue(payload["coldSucceeded"])
        self.assertEqual(payload["suspectCount"], 1)

    def test_bounded_cleanup_failure_refuses_cold_retry_without_losing_outcome(self) -> None:
        temporary, repo, store = self.make_repo()
        self.addCleanup(temporary.cleanup)
        self.create_build(repo)
        manager = self.manager(repo, store)
        context, _ = self.publish_seed(manager)
        key = context.snapshot.key
        (repo / ".build" / ".conductor-cache-provenance.json").write_text(
            json.dumps({"key": key}), encoding="utf-8"
        )
        ticket = "cleanup-failure"
        outcome = repo / f"{ticket}.cache-outcome.json"
        attempt_record = repo / f"{ticket}.cache-attempt.json"

        with mock.patch.object(
            conductor,
            "_run_cache_attempt",
            return_value=(1, False),
        ) as attempt, mock.patch.object(
            conductor,
            "_remove_cache_build_for_retry",
            return_value=False,
        ) as remove:
            code = conductor.operation_cache_retry(
                repo,
                {
                    "argv": ["swift", "build"],
                    "key": key,
                    "outcomePath": str(outcome),
                    "attemptTimeout": 19.0,
                    "cleanupTimeout": 41.0,
                    "attemptRecordPath": str(attempt_record),
                    "ticket": ticket,
                },
            )

        payload = json.loads(outcome.read_text(encoding="utf-8"))
        self.assertEqual(code, 1)
        attempt.assert_called_once_with(["swift", "build"], repo, 19.0, attempt_record, ticket)
        remove.assert_called_once_with(repo / ".build", 41.0)
        self.assertFalse(payload["coldRetryAttempted"])
        self.assertIn("bounded cleanup allowance", payload["reason"])
        self.assertTrue((repo / ".build").is_dir())

    def test_successful_cold_recovery_survives_advisory_suspect_bookkeeping_failure(self) -> None:
        temporary, repo, store = self.make_repo()
        self.addCleanup(temporary.cleanup)
        self.create_build(repo)
        manager = self.manager(repo, store)
        context, _ = self.publish_seed(manager)
        key = context.snapshot.key
        (repo / ".build" / ".conductor-cache-provenance.json").write_text(
            json.dumps({"key": key}), encoding="utf-8"
        )
        ticket = "bookkeeping-failure"
        outcome = repo / f"{ticket}.cache-outcome.json"
        attempt_record = repo / f"{ticket}.cache-attempt.json"

        with mock.patch.object(
            conductor,
            "_run_cache_attempt",
            side_effect=[(1, False), (0, False)],
        ), mock.patch.object(
            conductor.BuildCacheManager,
            "confirm_seeded_failure",
            side_effect=OSError("suspect bookkeeping fixture"),
        ):
            code = conductor.operation_cache_retry(
                repo,
                {
                    "argv": ["swift", "build"],
                    "key": key,
                    "outcomePath": str(outcome),
                    "attemptTimeout": 23.0,
                    "attemptRecordPath": str(attempt_record),
                    "ticket": ticket,
                },
            )

        payload = json.loads(outcome.read_text(encoding="utf-8"))
        self.assertEqual(code, 0)
        self.assertTrue(payload["coldSucceeded"])
        self.assertIn("suspect bookkeeping fixture", payload["suspectBookkeepingError"])
        self.assertEqual(
            conductor.BuildCacheManager.retry_job_timeout(23.0, conductor.BUILD_CACHE_CLONE_MAX_SECONDS),
            2 * 23.0
            + conductor.BUILD_CACHE_CLONE_MAX_SECONDS
            + conductor.BUILD_CACHE_RETRY_OVERHEAD_SECONDS,
        )


if __name__ == "__main__":
    unittest.main()
