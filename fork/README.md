# herdr fork tooling

Everything the personal hardened fork adds to upstream lives in `fork/` and `plans/`. Upstream never ships either directory, so rebasing onto new upstream commits has nothing to conflict with. The security audit and the decisions behind this setup are in `plans/security-audit-2026-10-19.md`.

Run every target as `make -C fork <target>` from the repository root. `make -C fork help` lists them.

## One-time setup

```sh
make -C fork tools            # cargo-deny, cargo-audit; osv-scanner is optional
make -C fork zig              # Zig 0.16.0 under fork/toolchain/, checksum pinned; builds use it automatically
make -C fork upstream-remote  # adds remote "upstream" -> https://github.com/herdrdev/herdr.git
make -C fork check-config     # ~/.config/herdr/config.toml must disable both background fetches
make -C fork verify           # build (ReleaseSafe parser, "-fork" version), cargo deny + cargo audit, binary check
make -C fork baseline         # first run only: accept the binary-check output, then commit fork/baseline/
make -C fork install          # PREFIX=/usr/local by default; use sudo or PREFIX=$HOME/.local
git config --global core.hooksPath /dev/null
```

Rules that need no tooling: never run `herdr update` or `herdr channel set`; decline plugins; integrations for agent state reporting are fine.

## Every upstream upgrade

```sh
make -C fork fetch
make -C fork sync-report              # OLD defaults to the merge-base with upstream, NEW to upstream/master
```

The report lands in `fork/reports/<date>_<old>_<new>/` and `summary.md` is printed. Review it with Claude Code or by hand:

```sh
claude "Follow fork/REVIEW.md for report fork/reports/<dir>"
```

To upgrade to a tag instead of master: `make -C fork sync-report NEW=v0.9.7`, then `make -C fork rebase NEW=v0.9.7`.

When the verdict allows it:

```sh
make -C fork rebase                   # git rebase onto NEW; the tree must be clean
make -C fork verify                   # fails on an advisory, a banned crate, or a binary-check delta
make -C fork baseline                 # only after reviewing a binary-check delta
make -C fork install
```

## What each check covers

| Step | Catches | Misses |
|---|---|---|
| `sync-report` | new or changed dependencies and sources, build-input changes, vendored parser bump, diffs of the watched paths (`watchlist.txt`), added lines matching `diff-patterns.txt`, new and binary files | semantic changes in files outside the watchlist; the review step exists for that |
| `cargo deny` (`deny.toml`) | RustSec advisories, yanked crates, non-crates.io sources, banned HTTP/TLS/Keychain/dlopen/git crates, crates shipping executables | nothing about Zig or C++ inputs |
| `cargo audit` | RustSec advisories against `Cargo.lock` | same |
| `binary-check` | new linked libraries or frameworks, new undefined symbols (keychain, TCC, dlopen, spawn), new embedded URLs or external command names, compared with the per-OS baseline | anything resolved at runtime by name rather than by symbol |
| `check-config` | background fetches re-enabled, plugins present, cached remote manifests | nothing else |

Ghostty (the vendored terminal parser) and Zig have no cargo coverage. When the sync report says the vendored commit changed, it prints the Ghostty compare and advisories links; read them. herdr itself publishes no security advisories.

## Files

- `Makefile`: targets above. Exports `LIBGHOSTTY_VT_OPTIMIZE=ReleaseSafe` and `HERDR_BUILD_CHANNEL=fork` for every build, and `ZIG` when `fork/toolchain/zig-0.16.0/` exists. Pass `ZIG=/path/to/zig` to use another install.
- `scripts/zig-install.sh`: downloads the pinned Zig release and verifies its checksum against the values recorded in the script.
- `scripts/sync-report.sh`, `scripts/deps-delta.sh`, `scripts/diff-grep.sh`: report generation.
- `scripts/binary-check.sh`: static binary checks, baseline diff.
- `scripts/check-config.sh`: local config verification.
- `watchlist.txt`, `diff-patterns.txt`: what the report diffs and flags.
- `deny.toml`: cargo-deny policy.
- `REVIEW.md`: the review prompt.
- `baseline/<os>/`: accepted binary-check output, committed.
- `reports/`, `out/`: generated, ignored by git.
