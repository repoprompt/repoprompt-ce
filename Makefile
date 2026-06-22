.PHONY: doctor setup install-format-tools format-tools-status format format-check lint install-debug-cli uninstall-debug-cli debug-cli-status resolve build run test guardrails conductor-selftest release-selftest release-sync-cli-version release-preflight release-artifact install-local-production xcode xcode-open xcode-generate xcode-check xcode-validate xcode-generator-test xcode-clean dev-status dev-build dev-swift-build dev-run dev-test dev-test-list dev-core-test dev-core-test-list dev-core-macos-test dev-core-macos-test-list dev-posix-test dev-posix-test-list dev-headless-build dev-headless-test dev-headless-test-list dev-headless-package dev-headless-provenance dev-headless-install dev-headless-status dev-headless-uninstall dev-headless-smoke dev-provider-test dev-provider-test-list dev-smoke dev-smoke-launch dev-format dev-format-check dev-lint dev-format-tools-status dev-check-format-tools dev-install-format-tools dev-release-preflight dev-release-artifact dev-install-local-production dev-stop-app dev-daemon-stop clean

PRODUCT ?= all
TARGET ?=
HEADLESS_CONFIGURATION ?= debug

doctor:
	./Scripts/doctor.sh

setup:
	./Scripts/install_format_tools.sh install
	./Scripts/doctor.sh
	swift package resolve

install-format-tools:
	./Scripts/install_format_tools.sh install

format-tools-status:
	./Scripts/install_format_tools.sh status

format:
	./Scripts/swift_style.sh format

format-check:
	./Scripts/swift_style.sh format-check

lint:
	./Scripts/swift_style.sh lint

install-debug-cli:
	./Scripts/install_debug_cli.sh install --build

uninstall-debug-cli:
	./Scripts/install_debug_cli.sh uninstall

debug-cli-status:
	./Scripts/install_debug_cli.sh status

resolve:
	swift package resolve

build:
	./Scripts/package_app.sh debug

run:
	./Scripts/run.sh

test:
	swift test

guardrails:
	./Scripts/source_layout_guardrails.sh
	./Scripts/contributor_allowlist_guardrails.sh
	./Scripts/swiftpm_notice_guardrails.sh

conductor-selftest:
	python3 Scripts/test_debug_app_process.py
	python3 Scripts/test_conductor_output.py
	python3 Scripts/test_agent_mode_file_tools_benchmark.py
	python3 Scripts/test_conductor_lifecycle.py
	python3 Scripts/test_local_production_installer.py
	python3 Scripts/test_security_inventory.py
	python3 Scripts/test_test_suite_optimizer.py

release-selftest:
	python3 Scripts/test_release_promotion.py
	python3 Scripts/test_release_tooling.py

release-sync-cli-version:
	./Scripts/release.sh sync-cli-version

release-preflight:
	./Scripts/release.sh preflight

release-artifact:
	./Scripts/release.sh artifact

install-local-production:
	./Scripts/install_local_production.sh

xcode: xcode-open

xcode-open: xcode-generate
	open "$$(python3 Scripts/generate_xcode_workspace.py print-path)"

xcode-generate:
	python3 Scripts/generate_xcode_workspace.py generate

xcode-check:
	python3 Scripts/generate_xcode_workspace.py check

xcode-validate: xcode-generate
	python3 Scripts/generate_xcode_workspace.py validate --xcodebuild-list

xcode-generator-test:
	python3 Scripts/test_xcode_workspace_generator.py

xcode-clean:
	rm -rf .build/xcode .build/xcode-custom

dev-status:
	./conductor status

dev-build:
	./conductor build

dev-swift-build:
	./conductor swift-build $(if $(TARGET),--target $(TARGET),--product $(PRODUCT))

dev-run:
	./conductor run

dev-test:
	./conductor test$(if $(FILTER), --filter $(FILTER))

dev-test-list:
	./conductor test --list

dev-core-test:
	./conductor core-test$(if $(FILTER), --filter $(FILTER))

dev-core-test-list:
	./conductor core-test --list

dev-core-macos-test:
	./conductor core-macos-test$(if $(FILTER), --filter $(FILTER))

dev-core-macos-test-list:
	./conductor core-macos-test --list

dev-posix-test:
	./conductor posix-test$(if $(FILTER), --filter $(FILTER))

dev-posix-test-list:
	./conductor posix-test --list

dev-headless-build:
	./conductor headless-build

dev-headless-test:
	./conductor headless-test$(if $(FILTER), --filter $(FILTER))

dev-headless-test-list:
	./conductor headless-test --list

dev-headless-package:
	./conductor headless-package --configuration $(HEADLESS_CONFIGURATION)

dev-headless-provenance:
	./conductor headless-provenance --configuration $(HEADLESS_CONFIGURATION)

dev-headless-install:
	./conductor headless-install --configuration $(HEADLESS_CONFIGURATION)

dev-headless-status:
	./conductor headless-status

dev-headless-uninstall:
	./conductor headless-uninstall --configuration $(HEADLESS_CONFIGURATION)$(if $(DELETE_STATE), --delete-state)

dev-headless-smoke:
	./conductor headless-smoke --configuration $(HEADLESS_CONFIGURATION)$(if $(SKIP_PACKAGE), --skip-package)

dev-provider-test:
	./conductor provider-test$(if $(FILTER), --filter $(FILTER))

dev-provider-test-list:
	./conductor provider-test --list

dev-smoke:
	./conductor smoke

dev-smoke-launch:
	./conductor smoke --launch

dev-format:
	./conductor format

dev-format-check:
	./conductor format-check

dev-lint:
	./conductor lint

dev-format-tools-status:
	./conductor format-tools-status

dev-check-format-tools:
	./conductor check-format-tools

dev-install-format-tools:
	./conductor install-format-tools

dev-release-preflight:
	./conductor release preflight

dev-release-artifact:
	./conductor release artifact

dev-install-local-production:
	./conductor release local-install

dev-stop-app:
	./conductor app stop

dev-daemon-stop:
	./conductor daemon stop

clean:
	rm -rf .build
