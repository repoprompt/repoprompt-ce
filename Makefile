.PHONY: help doctor setup install-format-tools format-tools-status format format-check lint install-debug-cli uninstall-debug-cli debug-cli-status resolve build run test guardrails conductor-selftest release-selftest release-sync-cli-version release-preflight release-artifact install-local-production xcode xcode-open xcode-generate xcode-check xcode-validate xcode-generator-test xcode-clean dev-status dev-build dev-swift-build dev-run dev-test dev-test-list dev-provider-test dev-provider-test-list dev-smoke dev-smoke-launch dev-format dev-format-check dev-lint dev-format-tools-status dev-check-format-tools dev-install-format-tools dev-release-preflight dev-release-artifact dev-install-local-production dev-stop-app dev-daemon-stop clean

PRODUCT ?= all

help:
	@printf '%s\n' 'Usage: make <target>'
	@printf '\n%s\n' 'Common targets:'
	@printf '  %-30s %s\n' 'doctor' 'Verify local Swift/Xcode setup and diagnostics'
	@printf '  %-30s %s\n' 'setup' 'Install format tools, run doctor, and resolve packages'
	@printf '  %-30s %s\n' 'build' 'Build and package the debug app'
	@printf '  %-30s %s\n' 'run' 'Build, package, and launch the debug app'
	@printf '  %-30s %s\n' 'test' 'Run the Swift test suite'
	@printf '  %-30s %s\n' 'guardrails' 'Run source layout and repository guardrails'
	@printf '  %-30s %s\n' 'clean' 'Remove .build'
	@printf '\n%s\n' 'Coordinated developer daemon targets:'
	@printf '  %-30s %s\n' 'dev-status' 'Show conductor daemon status'
	@printf '  %-30s %s\n' 'dev-build' 'Coordinated debug app package build'
	@printf '  %-30s %s\n' 'dev-swift-build' 'Coordinated Swift build; override with PRODUCT=name'
	@printf '  %-30s %s\n' 'dev-run' 'Coordinated debug app build and launch'
	@printf '  %-30s %s\n' 'dev-test' 'Coordinated test run; override with FILTER=name'
	@printf '  %-30s %s\n' 'dev-test-list' 'List XCTest methods through conductor'
	@printf '  %-30s %s\n' 'dev-provider-test' 'Run provider package tests; override with FILTER=name'
	@printf '  %-30s %s\n' 'dev-provider-test-list' 'List provider package tests'
	@printf '  %-30s %s\n' 'dev-smoke' 'Run non-disruptive live debug app smoke checks'
	@printf '  %-30s %s\n' 'dev-smoke-launch' 'Launch debug app, then run smoke checks'
	@printf '  %-30s %s\n' 'dev-stop-app' 'Stop the coordinated debug app'
	@printf '  %-30s %s\n' 'dev-daemon-stop' 'Stop the conductor daemon'
	@printf '\n%s\n' 'Style targets:'
	@printf '  %-30s %s\n' 'format' 'Format Swift files directly'
	@printf '  %-30s %s\n' 'format-check' 'Check Swift formatting directly'
	@printf '  %-30s %s\n' 'lint' 'Run direct format-check and SwiftLint'
	@printf '  %-30s %s\n' 'dev-format' 'Coordinated Swift formatting'
	@printf '  %-30s %s\n' 'dev-format-check' 'Coordinated Swift formatting check'
	@printf '  %-30s %s\n' 'dev-lint' 'Coordinated format-check and SwiftLint'
	@printf '  %-30s %s\n' 'install-format-tools' 'Install SwiftFormat and SwiftLint'
	@printf '  %-30s %s\n' 'format-tools-status' 'Show direct format tool status'
	@printf '  %-30s %s\n' 'dev-install-format-tools' 'Coordinated format tool install'
	@printf '  %-30s %s\n' 'dev-format-tools-status' 'Show coordinated format tool status'
	@printf '  %-30s %s\n' 'dev-check-format-tools' 'Check coordinated format tool availability'
	@printf '\n%s\n' 'Debug CLI targets:'
	@printf '  %-30s %s\n' 'install-debug-cli' 'Build and install the CE debug CLI'
	@printf '  %-30s %s\n' 'uninstall-debug-cli' 'Uninstall the CE debug CLI'
	@printf '  %-30s %s\n' 'debug-cli-status' 'Show CE debug CLI status'
	@printf '\n%s\n' 'Xcode workspace targets:'
	@printf '  %-30s %s\n' 'xcode' 'Generate and open the disposable Xcode workspace'
	@printf '  %-30s %s\n' 'xcode-generate' 'Generate the disposable Xcode workspace'
	@printf '  %-30s %s\n' 'xcode-check' 'Check generated Xcode workspace state'
	@printf '  %-30s %s\n' 'xcode-validate' 'Generate and validate the Xcode workspace'
	@printf '  %-30s %s\n' 'xcode-generator-test' 'Run Xcode workspace generator tests'
	@printf '  %-30s %s\n' 'xcode-clean' 'Remove generated Xcode workspace metadata'
	@printf '\n%s\n' 'Release targets:'
	@printf '  %-30s %s\n' 'release-preflight' 'Run release preflight directly'
	@printf '  %-30s %s\n' 'release-artifact' 'Build release artifact directly'
	@printf '  %-30s %s\n' 'install-local-production' 'Install a local production app'
	@printf '  %-30s %s\n' 'dev-release-preflight' 'Coordinated release preflight'
	@printf '  %-30s %s\n' 'dev-release-artifact' 'Coordinated release artifact build'
	@printf '  %-30s %s\n' 'dev-install-local-production' 'Coordinated local production install'
	@printf '\n%s\n' 'Internal/test targets:'
	@printf '  %-30s %s\n' 'resolve' 'Resolve Swift packages'
	@printf '  %-30s %s\n' 'conductor-selftest' 'Run conductor/tooling self-tests'
	@printf '  %-30s %s\n' 'release-selftest' 'Run release tooling self-tests'
	@printf '  %-30s %s\n' 'release-sync-cli-version' 'Sync CLI version for release tooling'

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
	./conductor swift-build --product $(PRODUCT)

dev-run:
	./conductor run

dev-test:
	./conductor test$(if $(FILTER), --filter $(FILTER))

dev-test-list:
	./conductor test --list

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
