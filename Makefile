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

.PHONY: ui-snap ui-snap-os26 ui-update ui-update-os26 ui-list ui-flow ui-flow-os26 ui-flow-frames ui-flow-update ui-flow-list ui-coverage ui-film ui-all

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

# The required semantic flow gate skips host-sensitive frame reconciliation;
# journals and named expectations are deterministic across hosted runners.
ui-flow:
	scripts/ui_harness.sh --mode flow-check --except os26 --no-frames

# The native gate for interactive behaviour. These flows release
# `RenderOverrides.forceLegacyGlass`, so they drive the native macOS 26 branch and
# only mean anything on a macOS 26 host; they are excluded from `ui-flow` above.
ui-flow-os26:
	scripts/ui_harness.sh --mode flow-check --only os26 --no-frames

# Frame rasters and accessibility geometry share the snapshot gate's display
# scale and font-rasterisation sensitivity, but remain valuable on known hosts.
ui-flow-frames:
	scripts/ui_harness.sh --mode flow-check --except os26

# Flow updates bless journals and frame goldens together so review sees one
# intentional semantic and visual cutover.
ui-flow-update:
	scripts/ui_harness.sh --mode flow-update --except os26

ui-flow-list:
	scripts/ui_harness.sh --mode flow-list

# Coverage is a pure declaration/claim ledger and never hosts or renders views.
ui-coverage:
	scripts/ui_harness.sh --mode coverage

# Media, never a golden: this records the README's recording-island GIF and
# nothing diffs, lints or gates its output. Needs ffmpeg on PATH.
ui-film:
	scripts/make_readme_gif.sh

# The complete local UI gate includes both scene and flow-frame goldens. The
# os26 legs need a macOS 26 host to render native glass, so they are conditional
# rather than excluded: on this hardware they are part of the gate.
ui-all: ui-snap ui-flow-frames
	@if [ "$$(sw_vers -productVersion | cut -d. -f1)" -ge 26 ]; then \
		$(MAKE) ui-snap-os26 ui-flow-os26; \
	else \
		echo "ui-all: skipping os26 gates (host < macOS 26)"; \
	fi

.PHONY: bench-smoke bench-stt bench-e2e bench-techterms bench-gate

N ?= 200
# Parakeet stays the measured default; override to A/B another registered
# backend, e.g. `make bench-stt BACKEND=apple N=64`.
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

.PHONY: bench-capture-plan bench-capture-run bench-capture-report

bench-capture-plan:
	cd bench && uv --no-config run python -m voiceour_bench.capture_matrix plan \
	  --prompts ../benchmarks/data/techterms/capture-prompts.jsonl \
	  --manifest ../benchmarks/data/techterms/capture-matrix.jsonl \
	  --output-dir ../benchmarks/data/techterms/real-speaker-audio \
	  --speaker-id speaker-001 --speaker-kind real --takes 2 --dry-run

bench-capture-run:
	cd bench && uv --no-config run python -m voiceour_bench.capture_matrix run \
	  --manifest ../benchmarks/data/techterms/capture-matrix.jsonl \
	  --results ../benchmarks/results/techterms-capture.results.jsonl \
	  --consent-confirmed

bench-capture-report:
	cd bench && uv --no-config run python -m voiceour_bench.capture_matrix report \
	  --manifest ../benchmarks/data/techterms/capture-matrix.jsonl \
	  --results ../benchmarks/results/techterms-capture.results.jsonl \
	  --output ../benchmarks/results/techterms-capture.report.json
