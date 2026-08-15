.PHONY: build test bundle verify-bundle fixture dev format format-check check-docs lint-python

build:
	swift build -Xswiftc -warnings-as-errors

# The UI harness test suites are compiled out unless UI_HARNESS is defined, so
# `swift test` on its own will not find them.
test:
	swift test -Xswiftc -warnings-as-errors -Xswiftc -DUI_HARNESS

# swift-format ships with the Swift 6 toolchain, so a contributor installs nothing.
# Configuration is .swift-format at the repo root.
format:
	swift format --in-place --recursive Sources Tests

format-check:
	swift format lint --strict --recursive Sources Tests

check-docs:
	scripts/check_docs.sh

# `bench/` is the only Python left in this repository, and it never ships.
lint-python:
	cd bench && uv --no-config run ruff check .

bundle:
	scripts/bundle.sh

verify-bundle:
	scripts/verify_bundle.sh

fixture:
	scripts/make_fixture.sh

dev:
	scripts/run_dev.sh

.PHONY: ui-snap ui-snap-os26 ui-update ui-update-os26 ui-list ui-flow ui-flow-os26 ui-flow-update ui-flow-list ui-all

# The portable gate. Runs on any host: every scene is pinned to the painted
# path by `RenderOverrides.forceLegacyGlass`, so these goldens are the ones CI
# and a macOS 14/15 machine can both reproduce.
ui-snap:
	scripts/ui_harness.sh --except os26

# The native Liquid Glass gate. Renders real system glass, so it only works on
# a macOS 26 host and its goldens are excluded from `ui-snap` above.
ui-snap-os26:
	scripts/ui_harness.sh --only os26

ui-update:
	scripts/ui_harness.sh --update --except os26

ui-update-os26:
	scripts/ui_harness.sh --update --only os26

ui-list:
	scripts/ui_harness.sh --list

# The required semantic flow gate checks deterministic journals and named expectations.
ui-flow:
	scripts/ui_harness.sh --mode flow-check --except os26

# The native gate for interactive behaviour. These flows release
# `RenderOverrides.forceLegacyGlass`, so they drive the native macOS 26 branch and
# only mean anything on a macOS 26 host; they are excluded from `ui-flow` above.
ui-flow-os26:
	scripts/ui_harness.sh --mode flow-check --only os26

# Flow updates bless intended journal changes.
ui-flow-update:
	scripts/ui_harness.sh --mode flow-update --except os26

ui-flow-list:
	scripts/ui_harness.sh --mode flow-list

# The complete local UI gate includes scene snapshots and semantic flow journals.
# The os26 legs need a macOS 26 host to render native glass, so they are conditional
# rather than excluded: on this hardware they are part of the gate.
ui-all: ui-snap ui-flow
	@if [ "$$(sw_vers -productVersion | cut -d. -f1)" -ge 26 ]; then \
		$(MAKE) ui-snap-os26 ui-flow-os26; \
	else \
		echo "ui-all: skipping os26 gates (host < macOS 26)"; \
	fi

.PHONY: bench-smoke bench-stt bench-e2e bench-techterms bench-gate

N ?= 200
# Parakeet is the only real backend; override only to measure the fake path.
BACKEND ?= parakeet

bench-smoke:
	cd bench && uv --no-config run python -m voiceour_bench.run --tier smoke --mode e2e --backend fake

bench-stt:
	cd bench && uv --no-config run python -m voiceour_bench.run --tier librispeech --mode stt --backend $(BACKEND) --n $(N)

bench-e2e:
	cd bench && uv --no-config run python -m voiceour_bench.run --tier fleurs --mode e2e --backend $(BACKEND) --n $(N)

bench-techterms:
	cd bench && uv --no-config run python -m voiceour_bench.run --tier techterms --mode stt --backend $(BACKEND)

# Usage: make bench-gate BASELINE=benchmarks/results/<a>.json CANDIDATE=benchmarks/results/<b>.json
bench-gate:
	cd bench && uv --no-config run python -m voiceour_bench.compare ../$(BASELINE) ../$(CANDIDATE) --gate uwer_final:0.0035
