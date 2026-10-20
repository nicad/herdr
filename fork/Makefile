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
# cargo audit fails only on vulnerabilities; unmaintained notices print as warnings and are
# gated by fork/deny.toml instead. Extra flags, e.g. AUDIT_IGNORE="--ignore RUSTSEC-2026-0001".
AUDIT_IGNORE    ?=

# Zig runtime safety checks stay on in the vendored terminal parser.
export LIBGHOSTTY_VT_OPTIMIZE ?= ReleaseSafe
# Only changes the reported version to <version>-fork; stable code paths stay selected.
export HERDR_BUILD_CHANNEL ?= fork

# herdr builds only with this exact Zig version. `make zig` installs it under fork/toolchain/
# and every build uses it; an explicit ZIG=/path/to/zig on the command line wins.
ZIG_VERSION := 0.16.0
TOOLCHAIN   := $(FORK)/toolchain
ZIG_LOCAL   := $(TOOLCHAIN)/zig-$(ZIG_VERSION)/zig
ifneq ($(wildcard $(ZIG_LOCAL)),)
export ZIG ?= $(ZIG_LOCAL)
endif

# Deferred: evaluated when a target uses them, after fetch.
OLD ?= $(shell cd $(ROOT) && git merge-base HEAD $(UPSTREAM_REF) 2>/dev/null)
NEW ?= $(UPSTREAM_REF)

BASELINE_FILES := linked-libs undefined-symbols flagged-symbols urls exec-strings

# Sandboxed build shell (nono). Everything except `install` and `git push` runs inside it.
NONO         ?= nono
NONO_PROFILE := $(FORK)/nono/herdr-build.json

.DEFAULT_GOAL := help
.PHONY: help shell nono-check tools zig upstream-remote check-config fetch sync-report rebase build audit binary-check baseline verify install clean

help:
	@echo "herdr fork workflow (make -C fork <target>)"
	@echo ""
	@echo "Sandbox:"
	@echo "  shell            open a nono-sandboxed shell in the repo; run the targets below inside it"
	@echo "  nono-check       validate the sandbox profile and show what it grants"
	@echo ""
	@echo "First time:"
	@echo "  tools            cargo install cargo-deny cargo-audit (osv-scanner optional)"
	@echo "  zig              install Zig $(ZIG_VERSION) under fork/toolchain/ (checksum pinned)"
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

shell:
	cd $(ROOT) && $(NONO) shell --profile $(NONO_PROFILE) --workdir $(ROOT) --allow-cwd --name herdr-build

nono-check:
	$(NONO) profile validate $(NONO_PROFILE)
	cd $(ROOT) && $(NONO) run --profile $(NONO_PROFILE) --workdir $(ROOT) --allow-cwd --dry-run -- make -C fork verify

tools:
	cargo install --locked cargo-deny cargo-audit
	@command -v osv-scanner >/dev/null 2>&1 || echo "optional second vulnerability database: brew install osv-scanner"

zig:
	$(SCRIPTS)/zig-install.sh $(ZIG_VERSION) $(TOOLCHAIN)

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
	@echo "zig: $${ZIG:-zig (from PATH)}"
	cd $(ROOT) && cargo build --release --locked
	@$(BIN) --version

audit:
	cd $(ROOT) && cargo deny --locked --config $(FORK)/deny.toml check
	cd $(ROOT) && cargo audit $(AUDIT_IGNORE)
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
