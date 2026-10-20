# Fork-only automation for the hardened herdr fork.
# Upstream never ships a fork/ directory, so rebases never conflict here.
# Run from anywhere: make -C fork <target>

ROOT     := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
FORK     := $(ROOT)/fork
SCRIPTS  := $(FORK)/scripts
REPORTS  := $(FORK)/reports
OS       := $(shell uname -s | tr '[:upper:]' '[:lower:]')
OUT      := $(FORK)/out/$(OS)
BASELINE := $(FORK)/baseline/$(OS)
BIN      := $(ROOT)/target/release/herdr

UPSTREAM_REMOTE ?= upstream
UPSTREAM_URL    ?= https://github.com/herdrdev/herdr.git
UPSTREAM_REF    ?= $(UPSTREAM_REMOTE)/master
PREFIX          ?= /usr/local
# RustSec ids to ignore in cargo audit, e.g. AUDIT_IGNORE="--ignore RUSTSEC-2026-0001"
AUDIT_IGNORE    ?=

# Zig runtime safety checks stay on in the vendored terminal parser.
export LIBGHOSTTY_VT_OPTIMIZE ?= ReleaseSafe
# Only changes the reported version to <version>-fork; stable code paths stay selected.
export HERDR_BUILD_CHANNEL ?= fork

# Deferred: evaluated when a target uses them, after fetch.
OLD ?= $(shell cd $(ROOT) && git merge-base HEAD $(UPSTREAM_REF) 2>/dev/null)
NEW ?= $(UPSTREAM_REF)

BASELINE_FILES := linked-libs undefined-symbols flagged-symbols urls exec-strings

.DEFAULT_GOAL := help
.PHONY: help tools upstream-remote check-config fetch sync-report rebase build audit binary-check baseline verify install clean

help:
	@echo "herdr fork workflow (make -C fork <target>)"
	@echo ""
	@echo "First time:"
	@echo "  tools            cargo install cargo-deny cargo-audit (osv-scanner optional)"
	@echo "  upstream-remote  add remote '$(UPSTREAM_REMOTE)' -> $(UPSTREAM_URL) if missing"
	@echo "  check-config     verify ~/.config/herdr/config.toml disables background fetches"
	@echo "  verify           build + audit + binary-check"
	@echo "  baseline         accept the current binary-check output as the $(OS) baseline"
	@echo "  install          install target/release/herdr to $(PREFIX)/bin"
	@echo ""
	@echo "Every upstream upgrade:"
	@echo "  fetch            git fetch $(UPSTREAM_REMOTE)"
	@echo "  sync-report      write $(REPORTS)/<date>_<old>_<new>/ for OLD..NEW"
	@echo "                   defaults: OLD=merge-base(HEAD, $(UPSTREAM_REF)) NEW=$(UPSTREAM_REF)"
	@echo "  rebase           git rebase NEW onto the current branch (clean tree required)"
	@echo "  verify, install"
	@echo ""
	@echo "Variables: OLD=<rev> NEW=<rev> UPSTREAM_REF=<ref> PREFIX=<dir> AUDIT_IGNORE='--ignore RUSTSEC-...'"

tools:
	cargo install --locked cargo-deny cargo-audit
	@command -v osv-scanner >/dev/null 2>&1 || echo "optional second vulnerability database: brew install osv-scanner"

upstream-remote:
	@cd $(ROOT) && git remote get-url $(UPSTREAM_REMOTE) >/dev/null 2>&1 || git remote add $(UPSTREAM_REMOTE) $(UPSTREAM_URL)
	@cd $(ROOT) && echo "$(UPSTREAM_REMOTE) -> $$(git remote get-url $(UPSTREAM_REMOTE))"

check-config:
	$(SCRIPTS)/check-config.sh

fetch: upstream-remote
	cd $(ROOT) && git fetch --tags $(UPSTREAM_REMOTE)

sync-report:
	$(SCRIPTS)/sync-report.sh "$(OLD)" "$(NEW)" "$(REPORTS)"

rebase:
	@cd $(ROOT) && test -z "$$(git status --porcelain --untracked-files=no)" || { echo "working tree has uncommitted changes; commit or stash first"; exit 1; }
	cd $(ROOT) && git rebase $(NEW)

build:
	cd $(ROOT) && cargo build --release --locked
	@$(BIN) --version

audit:
	cd $(ROOT) && cargo deny --locked check --config $(FORK)/deny.toml
	cd $(ROOT) && cargo audit --deny warnings $(AUDIT_IGNORE)
	@if command -v osv-scanner >/dev/null 2>&1; then cd $(ROOT) && osv-scanner scan source -L Cargo.lock; else echo "osv-scanner not installed; skipped"; fi

binary-check:
	$(SCRIPTS)/binary-check.sh "$(BIN)" "$(OUT)" "$(BASELINE)"

baseline:
	$(SCRIPTS)/binary-check.sh "$(BIN)" "$(OUT)"
	mkdir -p $(BASELINE)
	for f in $(BASELINE_FILES); do cp "$(OUT)/$$f.txt" "$(BASELINE)/"; done
	@echo "baseline accepted in $(BASELINE); review and commit it"

verify: build audit binary-check

install:
	install -m 755 $(BIN) $(PREFIX)/bin/herdr
	@$(PREFIX)/bin/herdr --version

clean:
	rm -rf $(FORK)/out
