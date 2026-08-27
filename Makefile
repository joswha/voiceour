# Voiceour is package-first: SwiftPM compiles it, `scripts/bundle.sh` assembles the
# .app, and this Makefile is the whole interface. `make` prints the catalogue, `make
# run` gets the real app running, `make check` is the gate. Nothing here needs an
# install beyond Apple's Command Line Tools, which ship both make and Swift.
#
# That make is GNU Make 3.81, which has no `.ONESHELL`, no `.SHELLFLAGS` and no
# `$(file ...)`. Every recipe line is its own `/bin/sh -c`, so a recipe that needs
# shell state across statements continues with `; \`, and no recipe may use a
# backtick: inside these double-quoted strings it would be command substitution.

SHELL := /bin/sh
.DEFAULT_GOAL := help
MAKEFLAGS += --no-print-directory --warn-undefined-variables

# SwiftPM holds an exclusive lock on `.build`, so two compiling targets can never
# really run at once. Serialising says so, and keeps `make check` in the order it
# documents instead of interleaving output under `-j`.
.NOTPARALLEL:

APP := .build/Voiceour.app
APP_BINARY := $(APP)/Contents/MacOS/Voiceour
DEBUG_BINARY := .build/debug/Voiceour

# Extra launch flags: `make run ARGS="--debug --show-console"`.
ARGS ?=

# One debug configuration for every debug target, so alternating `make build`,
# `make dev` and `make self-test` never invalidates SwiftPM's incremental state.
SWIFT_FLAGS := -Xswiftc -warnings-as-errors

# `pgrep -x` matches the process name exactly, which is what both the bundled app and
# the debug binary are called. The obvious `pgrep -f <bundle path>` would also match
# the recipe's own shell, whose argv holds that path, and kill this make run.
PGREP_APP := pgrep -x Voiceour

# Everything `scripts/bundle.sh` reads, so `make run` re-bundles exactly when one of
# those inputs moved and costs nothing when none did. SwiftPM still owns compilation.
#
# Directories are prerequisites too, not only files: deleting a source leaves no
# newer file behind, and without the directory's own mtime the bundle would keep a
# binary built from a file that no longer exists.
BUNDLE_INPUTS := Package.swift scripts/bundle.sh \
	$(shell find Sources Resources Vendor ! -name '.DS_Store')

.PHONY: help
help:
	@printf 'Voiceour — build, run and verify\n'
	@awk '/^#> / { printf "\n%s\n", substr($$0, 4); next } \
	      /^## / { line = substr($$0, 4); split_at = index(line, ": "); \
	               printf "  %-16s %s\n", substr(line, 1, split_at - 1), substr(line, split_at + 2) }' $(MAKEFILE_LIST)
	@printf '\nLaunch flags: make run ARGS="--debug --show-console"\n'
	@printf 'A .env at the repo root is sourced by run and dev: VOICEOUR_ASR_BACKEND,\n'
	@printf 'VOICEOUR_MODEL_VARIANT, VOICEOUR_SUPPORT_DIR.\n'

#> Build and run
.PHONY: build run dev stop status logs clean

## build: compile the debug build with warnings as errors
build:
	swift build $(SWIFT_FLAGS)

## run: build the real app, replace the running instance, launch it
#
# The stop is not a convenience: the app terminates a second instance of itself
# (Sources/Voiceour/VoiceourAppDelegate.swift), so the *newly built* bundle is the one
# that would quit and the old process would survive. Launching over a live instance
# without stopping it first means testing the previous build.
run: $(APP_BINARY)
	@$(MAKE) stop
	@if [ -f .env ]; then set -a; . ./.env; set +a; fi; \
	set --; \
	if [ -n "$${VOICEOUR_ASR_BACKEND:-}" ]; then set -- "$$@" --env "VOICEOUR_ASR_BACKEND=$$VOICEOUR_ASR_BACKEND"; fi; \
	if [ -n "$${VOICEOUR_MODEL_VARIANT:-}" ]; then set -- "$$@" --env "VOICEOUR_MODEL_VARIANT=$$VOICEOUR_MODEL_VARIANT"; fi; \
	if [ -n "$${VOICEOUR_SUPPORT_DIR:-}" ]; then set -- "$$@" --env "VOICEOUR_SUPPORT_DIR=$$VOICEOUR_SUPPORT_DIR"; fi; \
	open -n "$(APP)" "$$@" $(if $(ARGS),--args $(ARGS),)
	@for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do \
	  pid=$$($(PGREP_APP) 2>/dev/null | xargs); \
	  if [ -n "$$pid" ]; then printf 'run: %s is running (pid %s)\n' "$(APP)" "$$pid"; exit 0; fi; \
	  sleep 0.2; \
	done; \
	printf 'run: %s did not start; make logs or Console.app has the reason\n' "$(APP)" >&2; \
	exit 1

# `open` hands the launch to LaunchServices, the way a user starts the app. Measured on
# macOS 26, that launch does propagate this shell's environment — a bare `open -n` was
# observed delivering an unforwarded VOICEOUR_* name to the app — but nothing documents
# that as a contract, and `open --env` exists precisely because it is not one. So each
# name the app itself reads is forwarded explicitly above: the backend and the model
# variant from Sources/Voiceour/DictationCoordinator.swift, the support directory from
# Sources/VoiceCore/AppSupportPaths.swift. Add the forward here when the app learns to
# read another one, rather than relying on a macOS version's inheritance behaviour.

## dev: run the debug app on the fake backend, in this terminal
dev: build
	@if [ -f .env ]; then set -a; . ./.env; set +a; fi; \
	VOICEOUR_ASR_BACKEND="$${VOICEOUR_ASR_BACKEND:-fake}" $(DEBUG_BINARY) $(ARGS)

## stop: quit every running Voiceour process
#
# Silent when nothing is running, because `make run` calls it on every launch.
stop:
	@pids=$$($(PGREP_APP) 2>/dev/null | xargs); \
	if [ -z "$$pids" ]; then exit 0; fi; \
	printf 'stop: terminating Voiceour (pid %s)\n' "$$pids"; \
	kill $$pids 2>/dev/null || true; \
	for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do \
	  if ! $(PGREP_APP) >/dev/null 2>&1; then exit 0; fi; \
	  sleep 0.2; \
	done; \
	printf 'stop: no exit after 3s; sending SIGKILL\n' >&2; \
	kill -9 $$($(PGREP_APP) 2>/dev/null | xargs) 2>/dev/null || true

## status: what is built, what is running, what signed it
status:
	@pid=$$($(PGREP_APP) 2>/dev/null | xargs); \
	if [ -n "$$pid" ]; then printf 'process   running (pid %s)\n' "$$pid"; \
	else printf 'process   not running\n'; fi
	@if [ ! -x "$(APP_BINARY)" ]; then printf 'bundle    absent; make run builds it\n'; exit 0; fi; \
	if $(MAKE) -q $(APP_BINARY) >/dev/null 2>&1; then state="current"; else state="stale; make run rebuilds it"; fi; \
	printf 'bundle    %s (%s)\n' "$(APP)" "$$state"; \
	printf 'signature %s\n' "$$(codesign -dvv "$(APP)" 2>&1 | sed -n \
	  -e 's/^Authority=/signed by /p' \
	  -e 's/^Signature=adhoc$$/ad-hoc; make signing keeps permission grants across rebuilds/p' | \
	  head -1)"

## logs: stream Voiceour's unified-log output until interrupted
#
# `hotkey` is the only category the app logs today (VoiceMac/KeyboardShortcutsBinder.swift).
# The stop-path signposts are not log messages and need xctrace, not this.
logs:
	log stream --style compact --predicate 'subsystem == "com.voiceour.app"'

## clean: delete .build, vendored C++ objects included (slow to rebuild)
clean:
	rm -rf .build

#> Verify
.PHONY: check test self-test format format-check check-docs lint-python test-python

## check: the whole portable gate, in order
check: build format-check check-docs lint-python test ui-flow test-python self-test bench-smoke
	@printf 'check: gate passed\n'

# The UI harness test suites are compiled out unless UI_HARNESS is defined, so
# `swift test` on its own will not find them.
## test: the Swift suites, harness suites included
test:
	swift test $(SWIFT_FLAGS) -Xswiftc -DUI_HARNESS

## self-test: launch-path check on the fake backend; no model, no permission, no window
self-test: build
	$(DEBUG_BINARY) --self-test

# swift-format ships with the Swift 6 toolchain, so a contributor installs nothing.
# Configuration is .swift-format at the repo root.
## format: rewrite Sources and Tests in place
format:
	swift format --in-place --recursive Sources Tests

## format-check: fail on any formatting drift
format-check:
	swift format lint --strict --recursive Sources Tests

## check-docs: model pin, and every command the docs name, must be real
check-docs:
	scripts/check_docs.sh

# `bench/` is the only Python left in this repository, and it never ships.
## lint-python: ruff over the bench package
lint-python:
	cd bench && uv --no-config run ruff check .

## test-python: the bench package's own pytest suite
test-python:
	cd bench && uv --no-config run pytest

#> Bundle, sign, release
.PHONY: bundle verify-bundle signing notarize release fixture

## bundle: assemble and sign .build/Voiceour.app unconditionally
bundle:
	scripts/bundle.sh

# The incremental form of the same script: the target is the bundled executable, so
# `make run` re-bundles when an input moved and skips it when none did.
$(APP_BINARY): $(BUNDLE_INPUTS)
	scripts/bundle.sh

## verify-bundle: assert the shipped bundle's layout, plist, entitlements, signature
verify-bundle: $(APP_BINARY)
	scripts/verify_bundle.sh

## signing: install the stable local voiceour-dev identity (once per machine)
signing:
	scripts/setup_local_signing.sh

# Signs with the hardened runtime and submits to Apple notarization, so it needs a
# Developer ID identity in the keychain, notarytool credentials, and the network. It
# cannot run in CI: this repository holds no Apple secrets on purpose.
## notarize: sign, notarize, staple, validate, archive
notarize:
	scripts/sign_notarize.sh

# Cuts a source release: preflight, the full local gate, release notes read out of
# CHANGELOG.md, then the exact git tag and gh commands printed for the maintainer to run.
# It never tags, pushes or publishes, and it needs no Apple identity. The optional binary
# release is `scripts/release.sh --binary`, which adds `notarize` above and so carries the
# same Developer ID, network and no-CI conditions.
## release: source-release preflight; prints the publish commands
release:
	scripts/release.sh

## fixture: regenerate the committed audio fixture
fixture:
	scripts/make_fixture.sh

#> UI goldens
.PHONY: ui-snap ui-snap-os26 ui-update ui-update-os26 ui-list ui-flow ui-flow-os26 ui-flow-update ui-flow-list ui-all

# The portable gate. Runs on any host: every scene is pinned to the painted
# path by `RenderOverrides.forceLegacyGlass`, so these goldens are the ones CI
# and a macOS 14/15 machine can both reproduce.
## ui-snap: portable scene digests and AX dumps
ui-snap:
	scripts/ui_harness.sh --except os26

# The native Liquid Glass gate. Renders real system glass, so it only works on
# a macOS 26 host and its goldens are excluded from `ui-snap` above.
## ui-snap-os26: the native Liquid Glass scenes (macOS 26 host only)
ui-snap-os26:
	scripts/ui_harness.sh --only os26

## ui-update: bless intended portable scene changes
ui-update:
	scripts/ui_harness.sh --update --except os26

## ui-update-os26: bless intended native scene changes
ui-update-os26:
	scripts/ui_harness.sh --update --only os26

## ui-list: list the scene catalogue
ui-list:
	scripts/ui_harness.sh --list

# The required semantic flow gate checks deterministic journals and named expectations.
## ui-flow: portable semantic flow journals
ui-flow:
	scripts/ui_harness.sh --mode flow-check --except os26

# The native gate for interactive behaviour. These flows release
# `RenderOverrides.forceLegacyGlass`, so they drive the native macOS 26 branch and
# only mean anything on a macOS 26 host; they are excluded from `ui-flow` above.
## ui-flow-os26: native semantic flow journals (macOS 26 host only)
ui-flow-os26:
	scripts/ui_harness.sh --mode flow-check --only os26

# Flow updates bless intended journal changes.
## ui-flow-update: bless intended portable flow journals
ui-flow-update:
	scripts/ui_harness.sh --mode flow-update --except os26

## ui-flow-list: list the flow catalogue
ui-flow-list:
	scripts/ui_harness.sh --mode flow-list

# The complete local UI gate includes scene snapshots and semantic flow journals.
# The os26 legs need a macOS 26 host to render native glass, so they are conditional
# rather than excluded: on this hardware they are part of the gate.
## ui-all: every UI gate this host can run
ui-all: ui-snap ui-flow
	@if [ "$$(sw_vers -productVersion | cut -d. -f1)" -ge 26 ]; then \
		$(MAKE) ui-snap-os26 ui-flow-os26; \
	else \
		echo "ui-all: skipping os26 gates (host < macOS 26)"; \
	fi

#> Benchmarks
.PHONY: bench-smoke bench-stt bench-e2e bench-techterms bench-gate

N ?= 200
# Parakeet is the only real backend; override only to measure the fake path.
BACKEND ?= parakeet

## bench-smoke: offline fake-backend smoke run
bench-smoke:
	cd bench && uv --no-config run python -m voiceour_bench.run --tier smoke --mode e2e --backend fake

## bench-stt: LibriSpeech transcription accuracy (N=, BACKEND=)
bench-stt:
	cd bench && uv --no-config run python -m voiceour_bench.run --tier librispeech --mode stt --backend $(BACKEND) --n $(N)

## bench-e2e: FLEURS end-to-end report (N=, BACKEND=)
bench-e2e:
	cd bench && uv --no-config run python -m voiceour_bench.run --tier fleurs --mode e2e --backend $(BACKEND) --n $(N)

## bench-techterms: technical-term smoke run
bench-techterms:
	cd bench && uv --no-config run python -m voiceour_bench.run --tier techterms --mode stt --backend $(BACKEND)

# Usage: make bench-gate BASELINE=benchmarks/results/<a>.json CANDIDATE=benchmarks/results/<b>.json
## bench-gate: U-WER regression gate between two reports
bench-gate:
	cd bench && uv --no-config run python -m voiceour_bench.compare ../$(BASELINE) ../$(CANDIDATE) --gate uwer_final:0.0035
