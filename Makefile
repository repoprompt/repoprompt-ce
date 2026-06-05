.PHONY: doctor setup install-format-tools format-tools-status format format-check lint install-debug-cli uninstall-debug-cli debug-cli-status package-headless install-debug-headless uninstall-debug-headless headless-debug-status headless-smoke resolve build run test guardrails conductor-selftest release-selftest release-sync-cli-version release-preflight release-artifact install-local-production dev-status dev-guardrails dev-build dev-swift-build dev-run dev-test dev-provider-test dev-smoke dev-smoke-launch dev-package-headless dev-install-debug-headless dev-headless-debug-status dev-headless-smoke dev-format dev-format-check dev-lint dev-format-tools-status dev-check-format-tools dev-install-format-tools dev-release-preflight dev-release-artifact dev-install-local-production dev-stop-app dev-daemon-stop clean

PRODUCT ?= all
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

package-headless:
	./Scripts/package_headless.sh $(HEADLESS_CONFIGURATION)

install-debug-headless:
	./Scripts/install_headless_cli.sh install --configuration debug --build

uninstall-debug-headless:
	./Scripts/install_headless_cli.sh uninstall --configuration debug

headless-debug-status:
	./Scripts/install_headless_cli.sh status --configuration debug

headless-smoke:
	./Scripts/smoke_headless_mcp.sh --configuration $(HEADLESS_CONFIGURATION)

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
	bash ./Scripts/core_boundary_guardrails.sh
	python3 ./Scripts/test_shared_runtime_phase1_boundaries.py
	python3 ./Scripts/test_shared_runtime_phase2_slice1_boundaries.py
	./Scripts/contributor_allowlist_guardrails.sh
	./Scripts/swiftpm_notice_guardrails.sh

conductor-selftest:
	python3 Scripts/test_conductor_output.py
	python3 Scripts/test_conductor_lifecycle.py
	python3 Scripts/test_local_production_installer.py

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

dev-status:
	./conductor status

dev-guardrails:
	./conductor guardrails

dev-build:
	./conductor build

dev-swift-build:
	./conductor swift-build --product $(PRODUCT)

dev-run:
	./conductor run

dev-test:
	./conductor test$(if $(FILTER), --filter $(FILTER))

dev-provider-test:
	./conductor provider-test$(if $(FILTER), --filter $(FILTER))

dev-smoke:
	./conductor smoke

dev-smoke-launch:
	./conductor smoke --launch

dev-package-headless:
	./conductor package-headless $(HEADLESS_CONFIGURATION)

dev-install-debug-headless:
	./conductor install-headless-debug

dev-headless-debug-status:
	./conductor headless-debug-status

dev-headless-smoke:
	./conductor headless-smoke --configuration $(HEADLESS_CONFIGURATION)

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
