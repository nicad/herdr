# Herdr security audit for a hardened fork

Target: `master` at `143bf5fd` (v0.9.5), audited 2026-10-19. Read-only review of the full tree by five area audits, followed by an independent false-positive verification of every candidate finding. Nothing was executed except grep, git log and read-only shell.

The branch diff for `/security-review` was empty (clean master), so the review was run against the whole codebase using your stated threat model: upstream supply-chain compromise, data exfiltration, trojan/backdoor or persistence, and macOS Keychain or secret access.

## Current plan (decided 2026-10-20)

Goal for now: run upstream herdr on macOS and Linux with the smallest possible divergence from upstream, so rebases stay cheap, while keeping an on-demand audit step in the build procedure. Custom code waits until there is a concrete reason for it.

**Decisions.**

- No sandboxing of the server or of agent panes. Neither the seatbelt profile from section 7 nor the pane deny list from section 0 will be used; they create more operational problems than they solve. The socket API therefore stays reachable from panes, which is accepted: agents are not sandboxed anyway, so the socket adds no privilege they do not already have as the user.
- The build itself is sandboxed (added 2026-10-20). Building pulls in a second supply chain: crate build scripts and proc macros, the Zig build files of the vendored parser, and the dependency trees of cargo-deny and cargo-audit, all executing as the user. Every make target except `install` runs inside a nono shell (`fork/nono/herdr-build.json`, `make -C fork shell`) that denies credentials, keychains, browser data and shell configs, limits writes to the repository and the Rust and Zig caches, and allows network only to the build hosts listed in `fork/INSTALL.md`. nono is alpha software; it was chosen over Apple's `sandbox-exec` because it gives the same seatbelt policy on macOS plus a host allowlist and a Landlock equivalent on Linux, and because its profile can be reviewed in one JSON file. The residual risks are a trojaned build output, which only the binary baseline partially covers, and `~/.cargo/bin` being both writable in the sandbox and on `PATH`.
- Agent integrations and their hooks are allowed, because hook-reported state is more accurate than screen detection. The hooks only use `pane.report_agent` and `pane.report_agent_session`.
- No source patches for now (tier 3 skipped). The two config flags, the `ReleaseSafe` build, the fork build channel and the never-run `herdr update` cover the same ground without a diff.
- No scheduled checks. The vulnerability scan runs on demand as part of every rebuild, from the fork makefile.

**Build procedure (no code change).**

1. `~/.config/herdr/config.toml` sets `[update] version_check = false` and `manifest_check = false`; `make -C fork check-config` verifies it.
2. Build with `LIBGHOSTTY_VT_OPTIMIZE=ReleaseSafe` and `HERDR_BUILD_CHANNEL=fork` (the makefile exports both), `cargo build --release --locked`. The channel only changes the reported version string to `<version>-fork` and leaves the stable code paths selected.
3. Install the binary where agents cannot write (the makefile's `install` target, `PREFIX=/usr/local`). Never run `herdr update` or `herdr channel set`.
4. Decline plugins. Integrations may be installed.
5. `git config --global core.hooksPath /dev/null` for your own shells and for herdr's git spawns.

**Fork layout and rebase workflow.** `master` mirrors upstream `herdrdev/herdr`. The fork branch carries only `fork/`, which upstream never ships, so a rebase has nothing to conflict with. `fork/Makefile` automates the cycle; see `fork/README.md`:

```sh
make -C fork fetch sync-report     # report for <merge-base>..upstream/master under fork/reports/
claude "Follow fork/REVIEW.md for report fork/reports/<dir>"   # or read it yourself
make -C fork rebase verify install # rebase, build, cargo deny + cargo audit, binary baseline diff, install
```

The sync report contains the commit list, the diff of the watched paths (`fork/watchlist.txt`), the `Cargo.lock` delta with any non-crates.io source, the vendored libghostty-vt and build-input diff, every added line matching `fork/diff-patterns.txt`, and new or binary files. The binary check compares linked libraries, undefined symbols, embedded URLs and external command strings against a committed per-OS baseline; a delta fails `verify` until `make -C fork baseline` accepts it.

**Advisory feeds.** `cargo audit` and `cargo deny` run on every `verify`, so RustSec coverage is tied to rebuilds. Ghostty and Zig have no cargo coverage: when the sync report shows a vendored commit change, check the Ghostty compare link and advisories page it prints. Herdr itself publishes no advisories.

**Deferred, with the trigger that would revive each.** Report-only socket listener (if agents are ever sandboxed); git hook args and kitty medium patches (if a repo-local hook override or a graphics parser advisory appears); deleting plugin, remote and launchd code (if a sync report shows those areas growing network or privilege surface); server seatbelt profile (if a libghostty-vt memory-safety advisory lands before an upstream fix).

## 0. Decisions and follow-up answers (2026-10-19, second pass)

Usage model recorded: herdr runs either locally on macOS or directly on a remote Linux machine reached with mosh from iTerm2. Herdr's own SSH/remote-machine features, plugins, and agent-driven control of herdr will not be used. Multi-agent work only happens with a local herdr server.

**Turning off the two background fetches.** Possible today by config, no fork change required:

```toml
[update]
version_check = false    # herdr.dev/latest.json, preview.json, Homebrew formula API
manifest_check = false   # herdr.dev/agent-detection/index.toml and per-agent .toml
```

Both keys live in `UpdateConfig` (`src/config/model.rs:31-46`, defaults `true`). With both false a release build makes no outbound connection unless you run `herdr update`, `herdr channel set`, `herdr plugin install|update`, or a remote attach. For the fork, flip the two defaults so a missing or reset config cannot re-enable them, and stub `self_update` so `herdr update` cannot download either. Detection keeps working from the bundled manifests in `src/detect/manifests/`; the remote cache dir simply stays empty.

**Telemetry.** There is none to disable. The only outbound calls in the whole tree are the two fetches above, the Homebrew formula probe (part of `version_check`), `herdr update`, plugin install (`git` to GitHub), the remote-host installer, and `open <url>` on a link click. No analytics, crash reporting, or usage pings exist, and no request ever carries machine-derived data.

**Remote and plugin surfaces become dead code for you.** Not using herdr's SSH features removes Vuln 2 and the raw-stderr item from your exposure. Not running plugins removes the plugin runtime, startup and event hooks, link handlers, and the GitHub clone path. Both can be deleted from the fork or left inert; the frozen endpoint codec enums (`PluginSourceKind::Github` etc.) must stay in `src/api/schema` per the compatibility contract if you keep talking to upstream-built clients, which you will not, so you are free to remove them.

**Sandboxing the command socket without losing agent state tracking.** Agent state (`idle`/`working`/`blocked`) is read from the screen for every supported agent except OMP and MastraCode, which require their integration (`docs/next/website/src/content/docs/agents.mdx:18-37, 64`). Integrations add two things: session-id reporting so an agent resumes after a server restart, and for some agents hook-reported state that overrides screen reading. The shipped hooks call exactly two API methods: `pane.report_agent_session` (all of them) and `pane.report_agent` (kimi, mastracode, opencode, kilo, pi, omp). So:

- Simplest: do not install integrations. State tracking via screen detection keeps working for Claude Code, Codex, Cursor, Copilot and the rest; you lose automatic session resume. Then remove `HERDR_SOCKET_PATH` and `HERDR_BIN_PATH` from the pane environment in `apply_pane_base_env` (`src/integration/env.rs:28-33`) so nothing inside a pane can find the socket. Your macOS sandbox for the agent can additionally deny `file-write*`/connect on the socket path.
- If you want session resume: add a second listener in `src/api/server.rs` next to `start_server_inner` (`:81-97`) bound to `<socket>.report`, whose `handle_connection` accepts only `Method::PaneReportAgent` and `Method::PaneReportAgentSession` (`src/api/schema.rs:124-125`) and rejects everything else before dispatch. Export that path as `HERDR_SOCKET_PATH` in `apply_pane_base_env`; keep the full socket for the TUI and your own CLI use. The hooks need no change because they only use those two methods. Keep the `resume_argv` validation in `src/agent_resume.rs:58-89`, or drop reporter-supplied `resume_argv` entirely and rely on the built-in resume plans.

**Terminal output parser.** Pane output is parsed by libghostty-vt, the VT library extracted from the Ghostty terminal, written in Zig with vendored C++ (simdutf, highway, wuffs) under `vendor/libghostty-vt`, statically linked through the `crates/ghostty-vt` FFI bindings (about 480 `unsafe` sites in `bindings.rs` and `lib.rs`). It runs inside the herdr server process, which is outside any sandbox your agents run in. That is the real escape path you are describing: a memory-safety bug in libghostty-vt, reachable by bytes a sandboxed script prints, would execute in the unsandboxed server as your user. Mitigations in order of value: build the Zig side with `LIBGHOSTTY_VT_OPTIMIZE=ReleaseSafe` (default is `ReleaseFast`, `crates/ghostty-vt/build.rs:58`), which keeps Zig's bounds and overflow checks on at a performance cost; disable the kitty graphics file and shared-memory mediums in `crates/ghostty-vt/src/lib.rs:1077-1108` and consider disabling kitty graphics entirely since image decoding (the `png` crate plus the 49 KB experimental patch 0007) is the largest attacker-controlled parsing surface after the VT state machine; run the herdr server itself under a `sandbox-exec` profile on macOS (profile in section 7) so a parser compromise cannot reach the Keychain, `~/.ssh` or the network; track upstream Ghostty security fixes on every sync. The host-terminal input side (your keystrokes from iTerm2 or mosh) goes through `crossterm` and `termwiz`, which is a much smaller surface fed by a trusted source.

**Git hooks.** The only herdr code path that can run a repository hook is worktree creation (`git worktree add` runs `post-checkout`). Fork fix: in `repository_git_args` (`src/worktree.rs:160-169`) and the shared `noninteractive_process::command("git")` builder, always pass `-c core.hooksPath=/dev/null -c core.fsmonitor=false` and set `GIT_TERMINAL_PROMPT=0`. For your own shells, `git config --global core.hooksPath /dev/null` disables hooks everywhere, including your own, which matches the plan to replace them with manually run scripts. Agents working inside a repo can still write `.git/config`, so the herdr-side override matters even with the global setting in place.

**macOS features.** Decisions: drop launchd spawning and Mach bootstrap rehoming (use the Linux spawn path in `src/platform/mod.rs:360-363`; the cost is that quitting iTerm2 kills the server, which is acceptable when you quit deliberately); keep the osascript clipboard-image read (`src/platform/macos.rs:703-742`, only `TMPDIR` is interpolated, no untrusted input); keep desktop notifications (argv-separated, no injection path).

### Pane sandbox deny list (nono, seatbelt, Landlock) — recorded 2026-10-19, not pursued (decision 2026-10-20, see Current plan)

Question: when an agent runs under nono inside a herdr pane, is denying the socket API enough? No. The socket deny is necessary and removes the largest surface, but five other paths lead from a sandboxed pane back into the unsandboxed server or the next unsandboxed process, and on Linux the socket deny itself may not hold.

**Socket paths to deny.** The API socket is at a fixed, derivable location: `~/.config/herdr/herdr.sock`, or `~/.config/herdr/sessions/<name>/herdr.sock` for named sessions (`src/session.rs:163-187`). The TUI socket `herdr-client.sock` sits beside it. `XDG_CONFIG_HOME` relocates both. Hiding `HERDR_SOCKET_PATH` from the pane changes nothing because the default is computable; deny connect on the paths. The `herdr` CLI is only a socket client, so the deny covers `herdr agent ...`, `herdr pane ...`, and `herdr server reload-config` too.

**Cost.** The shipped hooks run inside the agent process and inherit its sandbox, so their socket calls fail. Lost: session-id reporting (automatic resume after a server restart) and hook-reported state for the agents that use it. Kept: screen-based detection, which runs in the server from PTY bytes and needs nothing from the pane.

**Paths the socket deny does not close:**

| Path | Why it matters | Sandbox rule |
|---|---|---|
| The PTY | Every byte the agent prints is parsed by libghostty-vt in the server. Cannot be denied. | None possible; mitigate with `ReleaseSafe` build and the server-side `sandbox-exec` profile (section 7). |
| `~/.config/herdr/` (writes) | Not just the socket. `config.toml` sets `default_shell`, tab-bar status items of `type = "command"` that the server runs on an interval (`src/config/model.rs:1550`), custom command keybinds, and the plugin list. `plugins/` is unsandboxed code (`src/plugin_paths.rs:6`). `agent-detection/` holds manifest overrides the server hot-reloads (`src/detect/manifest.rs:1122`). A write here is code execution outside the sandbox on the next reload, pane, or restart. | Deny write on the whole directory. Also deny write on `~/.local/state/herdr/` (remote manifest cache, `src/detect/manifest_update.rs:498`). |
| The herdr binary | `HERDR_BIN_PATH` names it. If its directory is writable (for example `~/.local/bin`), replacement is trivial. | Deny write on the binary and its directory. |
| Shell startup files | The pane shell runs outside the sandbox when nono wraps only the agent. A write to `~/.zshrc`, `~/.zprofile`, `~/.bashrc` runs unsandboxed in the next pane. Generic nono concern, but herdr spawns many shells. | Deny write on shell rc files (nono may already do this; verify). |
| Sibling pane terminals | Pane PTY slaves under `/dev/ttys*` (macOS) or `/dev/pts/*` (Linux) belong to the same user. Not verified what a sandboxed process can do to a sibling tty. | Deny `/dev/ttys*` and `/dev/pts/*` except the process's own controlling terminal, as cheap insurance. |

**Linux caveat.** nono uses seatbelt on macOS, which can deny `connect()` to a unix socket by path. On Linux it uses Landlock, whose filesystem rules do not govern `connect()` on a path-based unix socket; the newer IPC scoping covers abstract sockets only. On the mosh-connected Linux box a path deny on `herdr.sock` may therefore be a no-op. Verify from inside the sandbox before relying on it:

```sh
herdr agent list   # must fail
python3 -c 'import socket,os;s=socket.socket(socket.AF_UNIX);s.connect(os.path.expanduser("~/.config/herdr/herdr.sock"))'   # must fail
```

**Conclusion for the fork.** The sandbox is the wrong enforcement point: every agent on every machine needs the same deny list, and one gap voids it. The report-only listener (step 3 below) fixes it at the source. With it, the pane-reachable socket accepts only `pane.report_agent` and `pane.report_agent_session`, the full-control socket moves to a 0700 directory never exported to panes, and the nono deny list shrinks to the config directory, the binary, and shell rc files. Decision pending; options are (a) deny list only, (b) report-only listener only, (c) both.

### Revised fork change set (backlog; superseded by Current plan on 2026-10-20, none of these are applied)

1. Config defaults: `version_check = false`, `manifest_check = false` in `src/config/model.rs:43-44`.
2. Stub `self_update`/`auto_update` (`src/update.rs:2109`, `:2348`) and the remote installer (`src/remote/attach.rs:2680-2806`).
3. Remove `HERDR_SOCKET_PATH`/`HERDR_BIN_PATH` from pane env, or add the restricted report-only socket described above.
4. Git: `-c core.hooksPath=/dev/null -c core.fsmonitor=false`, `GIT_TERMINAL_PROMPT=0` on every spawn.
5. libghostty-vt: build `ReleaseSafe`; disable kitty file/shm mediums, or kitty graphics entirely.
6. Delete plugin runtime (`src/app/api/plugins/`, `src/cli/plugin.rs`, `src/plugin_*.rs`) and remote machine features (`src/remote/`, saved endpoints in `src/client/endpoint/`), or leave inert.
7. Drop launchd/Mach bootstrap (`src/platform/macos/launchd_spawn.rs`, `bootstrap.rs`).
8. At-rest: create `session.json` and logs 0600; remove the `raw_bytes` debug log at `src/raw_input.rs:192`; leave `experimental.pane_history` off.
9. Build identity: `HERDR_BUILD_CHANNEL=<fork>`; remove `.github/workflows`, `dependabot.yml`, `distribution/`.
10. Run the herdr server under the `sandbox-exec` profile from section 7 as a standing measure, since it is the one unsandboxed process that parses agent output.

## 1. Answers to your questions

**Keychain and secrets on macOS: nothing touches them.** No `Security.framework`, `security-framework` crate, `SecItem*`, `SecKeychain*`, `LocalAuthentication`, AppKit, `NSPasteboard`, `tccutil`, `~/Library/Keychains`, browser profile, or SSH private key reference exists in non-test code. The only Apple frameworks linked are Carbon (keyboard layout switching, `src/platform/macos.rs:253`), CoreFoundation (`:274`) and IOKit (sleep/wake, `src/platform/macos/power.rs:12`). The only `~/.ssh` reference is an `Include` of the public `~/.ssh/config` in a generated ssh config. `src/platform/ssh_agent.rs` is a symlink manager that points new panes at an existing same-uid agent socket; it never speaks the agent protocol, never signs, never forwards (`-A`/`ForwardAgent` appear nowhere).

**Exfiltration: no upload path exists.** There is no HTTP client crate, no `TcpStream`/`UdpSocket`/`TcpListener` anywhere in `src/`, and no telemetry, analytics or crash reporting. All HTTP is `curl` GET via `src/noninteractive_process.rs:10-12`. No request carries headers, bodies or URL parameters derived from the machine. Clipboard read via OSC 52 (`?`) is not implemented (verified in libghostty wrapper and tests), so a pane cannot read your clipboard through the terminal protocol. Environment variables are never persisted or logged. The one process-environment read (`KERN_PROCARGS2`, `src/platform/macos.rs:609-643`) extracts only `HERDR_AGENT=` from a stack buffer that is dropped.

**Backdoor and persistence: none found, but two remote-control channels exist by design.** No writes to shell rc files, LaunchAgents, login items or profiles. The launchd plist (`src/platform/macos/launchd_spawn.rs:197-239`) is `RunAtLoad=true, KeepAlive=false`, written to a 0700 temp dir that is deleted immediately and submitted with `launchctl bootstrap gui/<uid>`; it does not survive logout. The two channels that let upstream infrastructure change behaviour on your machine without a code review are the self-updater and the remote agent-detection manifests (both detailed below). Both are the first things to disable in a fork.

**Background network calls in a release build with default config:**

| Call | Destination | When | Response controls |
|---|---|---|---|
| version check (`src/update.rs:336-360`) | `https://herdr.dev/latest.json` or `preview.json`; Homebrew formula API if installed via brew | server/App start and every 30 min (`src/app/mod.rs:591-597`, `src/app/runtime.rs:95-120`) | "update available" banner, release-notes text, binary URL and sha256 used later by `herdr update` |
| agent-detection catalog (`src/detect/manifest_update.rs:509-557`) | `https://herdr.dev/agent-detection/index.toml` plus one `.toml` per agent | same schedule (`src/app/mod.rs:599-605`) | regex-only detection rules, schema `deny_unknown_fields`, no command/path/URL fields; hot-reloaded into state |
| ssh to saved machines | user-configured hosts with `enabled = true` | TUI client start | remote herdr frames |

Both herdr.dev calls are config-gated (`[update] version_check` and `manifest_check`, `src/config/model.rs:33-46`) and disabled in debug builds (`src/app/mod.rs:181-186`). The background check never installs anything.

## 2. Confirmed findings

# Vuln 1: Unsigned update manifest; download URL and expected digest come from one unauthenticated origin: `src/update.rs:403-414`, `src/update.rs:645-665`

* Severity: High under your threat model (Medium under a generic one; it is a missing control, not a code defect). Verifier confidence 8.
* Description: Manifests are fetched with `curl -sfL` and the asset URL plus its SHA-256 are both read from the same JSON body (`src/update.rs:403-414`, preview path `:494-517`). The download follows the manifest URL with no host or scheme restriction and no `--proto`/`--proto-redir` pin, and the only check is digest equality (`src/checksum.rs:9-26`). No signature, no pinned key, no cross-check against GitHub release metadata even though the digests originate from GitHub CI (`scripts/changelog.py:418-426`). Same structure in `distribution/install.sh:45-109`, `distribution/install.ps1`, and the remote-host installer `src/remote/attach.rs:2680-2704`. On the preview channel the digest is optional and skipped when absent (`:517`, `:657`). The binary replaces `current_exe()` by rename (`:693`). Install is user-triggered only: `herdr update`, `herdr channel set` (which runs a full self-update immediately, `src/cli.rs:239`), remote attach after a prompt, or the install script.
* Exploit Scenario: Whoever can change the content served at `herdr.dev/latest.json` (private website repo, Cloudflare Pages account, or a master commit to `distribution/latest.json` via the release deploy key or bot token) publishes a manifest with a higher version, an attacker-hosted URL and the matching SHA-256. All running clients prompt that an update is available; any user who runs `herdr update` receives and executes the attacker binary. Compromise of the GitHub repository is not required.
* Recommendation for the fork: remove or stub `self_update` and `auto_update` (`src/update.rs:2109`, `:2348`) and point the channel constants at your own distribution or nothing. If you keep an updater, sign the manifest with a key embedded in the binary, restrict asset URLs to a fixed host, pass `--proto '=https' --proto-redir '=https'` to every curl call, and make `sha256` mandatory on the preview path.

# Vuln 2: Terminal escape injection from a remote endpoint into the host terminal: `src/client/mod.rs:1625-1642`, `src/protocol/render_ansi.rs:987`

* Severity: Low (concrete and trivially exploitable by a hostile remote server, but the impact equals what a plain `ssh host` already grants; herdr makes no stronger isolation claim in its docs). Verifier confidence 8 on the code path.
* Description: In endpoint mode the client requires a `SemanticFrame` handshake (`src/client/endpoint/supervisor.rs:510`) but then accepts and executes every `ServerMessage` variant from the active endpoint (`src/client/mod.rs:1503-1510`, `src/client/endpoint/message_policy.rs:19-45`). `ServerMessage::Terminal(frame).bytes` and `ServerMessage::Graphics { bytes }` are written to stdout verbatim although no legitimate server emits them for a semantic client (`src/server/render_stream.rs:116-118`; `Graphics` has no producer at all). `CellData.symbol` strings from `PaneSurface` are emitted without stripping C0/C1 controls, while hyperlinks, titles, notifications and `GraphicsFile` paths on the same path are sanitized. Host stdin, including terminal query responses, is forwarded raw to the active endpoint (`mod.rs:992-1041`).
* Exploit Scenario: A compromised saved machine runs a modified `herdr remote-client-bridge` (the local client executes whatever `herdr` the remote host serves, `src/remote/attach.rs:416-435`). Once selected, it sends a `Terminal` frame or a cell symbol containing an OSC 52 clipboard write, a title change, or capability queries whose answers return to it as input. Herdr's own sanitizers are bypassed.
* Recommendation: drop `Terminal` and `Graphics` messages on connections negotiated as `SemanticFrame` (treat as protocol error like the `ClientShellSnapshot` case at `mod.rs:1521-1546`); in `write_cell` replace symbols containing `char::is_control()` with a space, mirroring `sanitized_hyperlink_uri`.

## 3. Verified but not vulnerabilities (hardening backlog for the fork)

These were real code paths confirmed by the verifiers but rejected as vulnerabilities because herdr adds no capability beyond what the user or a standard terminal already grants.

- **Git hooks on worktree creation** (`src/worktree.rs:160-169, 239-278`). `git worktree add` runs the repository's `post-checkout` hook; herdr passes no `-c core.hooksPath=` and inherits the full server env. Parity with running git by hand, so Low. The background spawns (`symbolic-ref`, `rev-parse --verify`, `rev-list --count`) do not read the index and cannot trigger `core.fsmonitor` or hooks. Cheap fix: add `-c core.hooksPath=/dev/null -c core.fsmonitor=false` and `GIT_TERMINAL_PROMPT=0` to the shared git builder.
- **OSC 7 overrides the real process cwd** (`src/pane.rs:3807-3819`, validation only `is_absolute && is_dir`). Today it only steers read-only git queries and new-pane cwd, so no exploit. It becomes one the day an index-refreshing git command is added to the background worker. Same fix as above plus preferring the real cwd.
- **OSC 52 clipboard writes** from any pane or the active remote endpoint set the local clipboard (`src/server/headless/notifications.rs:334-339`, `src/client/mod.rs:2009`). Matches iTerm2/kitty/Ghostty/tmux defaults; a generic "copied" toast is shown. Optional: config gate scoped by endpoint locality, distinct toast text.
- **Raw remote stderr during interactive attach** (`src/remote/attach.rs:1224-1246`, `3277-3281`). Identical exposure to running `ssh` yourself. Note the inherited stderr stays open while the TUI runs.
- **Linked plugins hot-reload their manifests** (`src/persist/plugin_registry.rs:139-159`). `plugin link` is a documented developer path; plugins are already arbitrary code, so a manifest hash would not be a boundary.
- **Full API socket in every pane's environment.** Every pane, hook and plugin gets `HERDR_SOCKET_PATH` to the complete JSON API (0600, same-uid), which can type into any pane, create panes with arbitrary commands, link plugins and register `resume_argv` that is typed into a shell on restore (`src/agent_resume.rs:58-89`, quoting verified). Same-user, so not a boundary violation, but a fork could offer a restricted socket exposing only `pane.report_agent*`.
- **At-rest hygiene.** `session.json` and log files are created with umask default rather than 0600 (`src/persist/io.rs:55-62`, `src/logging.rs:498-505`); `launch_argv` of panes created with a command is persisted; `[experimental] pane_history = true` writes full ANSI scrollback of every pane to disk (default off); `HERDR_LOG=debug` logs every client keystroke as `raw_bytes` (`src/raw_input.rs:192`).
- **Kitty graphics file medium** is enabled server-side (`crates/ghostty-vt/src/lib.rs:1077-1108`): a pane process can have the server read any regular file and render it. Same uid, no readback, and `GraphicsFile` paths are refused for SSH endpoints (`src/client/mod.rs:1659-1672`). Disable `t=f` and `t=s` if you do not need them.

Ruled out entirely: command injection into `osascript`/`open`/`sh`/`launchctl` (all argv-separated or scheme-filtered; `open` accepts only `http://`/`https://` after a click, `src/app/actions.rs:1053-1055`); repo-local config loading (config comes only from `$HERDR_CONFIG_PATH` or the config dir, no include directive); implicit plugin discovery; automatic integration install or silent migration (`HERDR_INTEGRATION_VERSION` is compared on read, never auto-applied); `pull_request_target` abuse in CI (no PR code is executed); unpinned actions (all 14 are SHA-pinned).

## 4. What integrations write outside herdr's directories

Only on explicit `herdr integration install <target>` or the Settings "install recommended integrations" action (which installs every detected agent at once, `src/client/shell/settings.rs:247-285`). Each target gets a hook script (0755) under its own config dir plus a config edit registering it, for example `~/.claude/hooks/herdr-agent-state.sh` and a `SessionStart` entry in `~/.claude/settings.json`. Every shipped hook exits unless `HERDR_ENV=1` and the socket env are set, then reports session state to the local unix socket; none makes a network call. Exceptions worth knowing: the Devin hook runs `devin list` from `PATH`; Hermes/qodercli/qwen/letta hooks run the `herdr` binary; Kimi registers 12 hook events and mastracode 11, so those run on every tool call. Uninstall removes them.

## 5. Build and release supply chain

- `cargo build --release --locked` compiles committed source plus crates.io crates pinned in `Cargo.lock` (no git deps). `crates/ghostty-vt/build.rs` runs `zig build` on the vendored libghostty-vt, which on first build downloads `uucode`, `highway` and `wuffs` tarballs from `deps.files.ghostty.org`, each verified against a content hash committed in `build.zig.zon`. Setting `LIBGHOSTTY_VT_ZIG_SYSTEM_DIR` or using `nix build` makes this hermetic (`nix/package.nix:152-163`).
- Zig 0.16.0 is required but not hash-pinned by the repo; verify the ziglang.org minisign signature yourself.
- Vendored trees (libghostty-vt at upstream commit `44f2a44d`, six patches; portable-pty 0.9.0 with four patches) are checked structurally only: the tests confirm patches reverse-apply, not that the tree matches upstream. Diff against upstream on each sync.
- Released macOS binaries are built on floating `macos-latest` images with a restored `Swatinem/rust-cache`, are not codesigned, notarized or attested, and the digest in `latest.json` is taken from the GitHub Releases API rather than the build runner. Bit-for-bit reproduction against upstream assets is not realistic; a local build removes the release pipeline from your trust base entirely.

## 6. Minimal fork change set, in order

1. Set `version_check` and `manifest_check` defaults to `false` (`src/config/model.rs:43-44`) or hard-code `auto_updates_enabled = false` (`src/app/mod.rs:181-183`). Zero background egress after this.
2. Stub `self_update` and the remote-host download (`src/update.rs:603-800`, `src/remote/attach.rs:2680-2806`). Keep `Version` and package-manager detection, which other modules import.
3. Apply the Vuln 2 client-side filters and the git `-c core.hooksPath=/dev/null` hardening.
4. Disable kitty file/shm mediums; consider gating OSC 52 writes per endpoint.
5. Build with `HERDR_BUILD_CHANNEL=<fork>` so `herdr --version` identifies fork builds; remove `.github/workflows`, `dependabot.yml` and `distribution/` installers.
6. Optional macOS surface reductions, each with a documented cost: drop launchd/Mach bootstrap rehoming (server dies when the launching terminal quits), drop osascript clipboard-image read (image paste stops), drop desktop notifications (falls back to in-terminal toasts), drop Carbon input-source switching (affects non-Latin layouts in prefix mode).

## 7. Audit tooling, now and on every rebuild

Tool versions and maintenance status were checked on 2026-10-19; items marked unverified were not confirmed.

| Tool | Catches | Install | Command for this repo | Cadence | Gate |
|---|---|---|---|---|---|
| cargo-deny 0.20.x | advisories, yanked crates, non-crates.io sources, banned capability crates (HTTP, TLS, keychain, dlopen), crates shipping executables or build scripts | `cargo install --locked cargo-deny` | `cargo deny --locked check` with the `deny.toml` below | every build | block |
| baseline diff (no tool) | new spawn/network call sites, new imports, new URL strings, new unsafe, new deps | none | see post-build script and `just audit-fast` | every build | block until re-baselined |
| cargo-audit 0.22 + cargo-auditable | RustSec vulns in `Cargo.lock` and in the shipped binary | `cargo install --locked cargo-audit cargo-auditable` | `cargo audit --deny warnings`; build with `cargo auditable build --release --locked`; `cargo audit bin target/release/herdr` | every build | block on vulns |
| cargo-vet 0.10 | unreviewed crate versions; new crates on sync fail until audited | `cargo install --locked cargo-vet` | `cargo vet init && cargo vet import mozilla google bytecode-alliance embark-studios zcash isrg && cargo vet` | once, then every sync | block |
| osv-scanner 2.x | second vuln DB over `Cargo.lock`; OSV API by commit for highway/wuffs | `brew install osv-scanner` | `osv-scanner scan source -L Cargo.lock` | every sync | report |
| clippy 1.96.1 audit pass | deterministic list of every `Command::new`, socket connect, `dlopen`, `include_bytes!`, undocumented unsafe | toolchain component | see `.audit/clippy.toml` below; sort output and diff against baseline | every build | block on diff |
| cargo-supply-chain | publisher changes per crate | `cargo install --locked cargo-supply-chain` | `cargo supply-chain publishers` and diff | every sync | report |
| gitleaks / trufflehog | leaked credentials in the sync range | `brew install gitleaks trufflehog` | `gitleaks git --log-opts="<last-sync>..HEAD" .`; `trufflehog git file://. --since-commit <last-sync> --only-verified --fail` | every sync | block |
| semgrep | pattern rules for `sh -c`, unsafe, temp dirs; `p/0xdea` C/C++ rules over vendored simdutf/wuffs/highway | `brew install semgrep` | `semgrep --config p/rust --config p/0xdea --metrics=off --error src crates vendor/libghostty-vt/pkg/{simdutf,wuffs,highway}` | every sync | report |
| cargo-geiger 0.14 | unsafe counts per crate incl. deps | `cargo install --locked cargo-geiger` | `cargo geiger --locked --output-format Ascii` and diff | every sync | report |
| zizmor | CI supply-chain issues in `.github/workflows` | `brew install zizmor` | `zizmor --min-severity medium .github/` | every sync | report |
| CodeQL CLI 2.27 (Rust GA, build-mode none) | taint queries: command injection, path traversal | `brew install codeql`; `codeql pack download codeql/rust-queries` | `codeql database create .audit/codeql-db --language=rust --build-mode=none --source-root .`; `codeql database analyze .audit/codeql-db codeql/rust-queries:codeql-suites/rust-security-extended.qls --format=sarif-latest --output=.audit/out/codeql.sarif` | weekly or per sync | report |
| cargo-careful | UB at runtime in tests; works with FFI | `cargo +nightly install --locked cargo-careful` | `LIBGHOSTTY_VT_OPTIMIZE=ReleaseSafe cargo +nightly careful test` | when unsafe/FFI/vendor changed | report |
| AddressSanitizer (nightly) | memory errors across the Rust/libghostty boundary | nightly + `rust-src` | `RUSTFLAGS=-Zsanitizer=address cargo +nightly test -Zbuild-std --target aarch64-apple-darwin --lib` | when vendor changed | report |
| eslogger (built into macOS, needs root + Full Disk Access) | exact spawns, file opens, unix-socket connects of the running binary | built in | `sudo eslogger exec fork open create rename unlink uipc_connect \| jq -c 'select(.process.executable.path\|test("herdr"))'` | runtime, every build | manual review |
| Objective-See ProcessMonitor / FileMonitor / LuLu | same as eslogger with signing info and easier filters; LuLu prompts on first outbound connection per binary | objective-see.org | `sudo ProcessMonitor -pretty -filter herdr`; `sudo FileMonitor -pretty -filter herdr` | runtime | manual review |
| Santa (monitor mode) | continuous exec log of herdr and children | github.com/northpolesec/santa | grep `santa.log` for parent herdr | continuous | manual review |
| sandbox-exec (deprecated, still works) | deny-by-default profile turns unexpected syscall classes into logged violations | built in | `sandbox-exec -f .audit/herdr-smoke.sb target/release/herdr ...` | runtime, every build | block on violation |
| diffoscope | structured diff of consecutive builds | `brew install diffoscope` | `diffoscope old/herdr new/herdr --html .audit/out/diff.html` | every build | manual review |

cargo-vet coverage estimate: 219 of 280 third-party crates (78%) appear in Mozilla, Google and Bytecode Alliance audits by name, 227 (81%) adding Embark, Zcash and ISRG. Version-level coverage will be lower; `cargo vet suggest` gives the real number. The remaining backlog is roughly 25 to 30 crates for macOS plus Linux after excluding Windows-only ones (`ratatui-*`, `wezterm-*`, `zbus`, `interprocess`, `signal-hook`, `fancy-regex`, `jsonc-parser`, and small utilities).

Zig and C/C++ dependencies are outside cargo tooling. Integrity is enforced at fetch time by the `build.zig.zon` content hashes; vulnerability coverage is manual: diff the `.zon` files on each sync and query OSV by upstream commit, for example `curl -sd '{"commit":"<highway commit>"}' https://api.osv.dev/v1/query`. Run tests and the smoke session with `LIBGHOSTTY_VT_OPTIMIZE=ReleaseSafe` to keep Zig's runtime safety checks on.

### deny.toml (starting point)

Prune the license list after the first run. Seed `allow-build-scripts` from the first `cargo deny check bans` output. The `[bans.build]` field names were written from the docs as remembered and not re-verified; `cargo deny` rejects unknown keys, so the first run validates them.

```toml
[graph]
targets = ["aarch64-apple-darwin", "x86_64-apple-darwin", "x86_64-unknown-linux-gnu", "aarch64-unknown-linux-gnu"]

[advisories]
db-urls = ["https://github.com/rustsec/advisory-db"]
yanked = "deny"
ignore = []

[licenses]
allow = ["Apache-2.0", "Apache-2.0 WITH LLVM-exception", "MIT", "BSD-2-Clause", "BSD-3-Clause", "ISC", "Zlib", "0BSD", "Unicode-3.0", "Unicode-DFS-2016", "MPL-2.0", "WTFPL"]
confidence-threshold = 0.9

[bans]
multiple-versions = "warn"
wildcards = "deny"
allow-wildcard-paths = true
deny = [
  { crate = "reqwest", reason = "no in-process HTTP; curl subprocess only" },
  { crate = "ureq", reason = "no in-process HTTP" },
  { crate = "hyper", reason = "no in-process HTTP" },
  { crate = "curl", reason = "no in-process HTTP" },
  { crate = "curl-sys", reason = "no in-process HTTP" },
  { crate = "openssl-sys", reason = "no TLS stack" },
  { crate = "native-tls", reason = "no TLS stack" },
  { crate = "rustls", reason = "no TLS stack" },
  { crate = "hickory-resolver", reason = "no DNS" },
  { crate = "security-framework", reason = "no Keychain access" },
  { crate = "security-framework-sys", reason = "no Keychain access" },
  { crate = "keyring", reason = "no Keychain access" },
  { crate = "core-graphics", reason = "no screen capture / TCC surfaces" },
  { crate = "objc2-app-kit", reason = "review before allowing AppKit" },
  { crate = "objc2-foundation", reason = "review before allowing Foundation" },
  { crate = "libloading", reason = "no dlopen" },
  { crate = "dlopen2", reason = "no dlopen" },
  { crate = "git2", reason = "git stays an external process" },
  { crate = "ssh2", reason = "ssh stays an external process" },
]

[bans.build]
allow-build-scripts = []   # seed from first run, then keep closed
executables = "deny"
interpreted = "deny"
include-dependencies = true
include-archives = true

[sources]
unknown-registry = "deny"
unknown-git = "deny"
allow-registry = ["https://github.com/rust-lang/crates.io-index"]
allow-git = []
```

### .audit/clippy.toml (audit pass only, selected with `CLIPPY_CONF_DIR=.audit`)

```toml
too-many-arguments-threshold = 11
allow-unwrap-in-tests = true
allow-expect-in-tests = true
disallowed-methods = [
  { path = "std::process::Command::new", reason = "audit: process spawn" },
  { path = "tokio::process::Command::new", reason = "audit: process spawn" },
  { path = "std::net::TcpStream::connect", reason = "audit: network" },
  { path = "std::net::TcpListener::bind", reason = "audit: network" },
  { path = "std::net::UdpSocket::bind", reason = "audit: network" },
  { path = "tokio::net::TcpStream::connect", reason = "audit: network" },
  { path = "std::os::unix::net::UnixStream::connect", reason = "audit: ipc (baseline expected)" },
  { path = "libc::system", reason = "audit: shell" },
  { path = "libc::execv", reason = "audit: exec" },
  { path = "libc::execvp", reason = "audit: exec" },
  { path = "libc::dlopen", reason = "audit: dynamic loading" },
  { path = "libc::setuid", reason = "audit: privilege" },
  { path = "std::env::set_var", reason = "audit: env mutation" },
  { path = "std::fs::remove_dir_all", reason = "audit: destructive fs" },
]
disallowed-macros = [
  { path = "std::include_bytes", reason = "audit: embedded blob" },
]
```

Run with `-W clippy::disallowed_methods -W clippy::disallowed_macros -W clippy::undocumented_unsafe_blocks -W clippy::multiple_unsafe_ops_per_block -W unsafe_code`, pipe through `grep 'warning: ' | sort`, and diff against a committed baseline. The goal is a sorted list of call sites, not a passing lint.

### Post-build macOS verification script (static part, seconds)

```bash
#!/bin/sh
set -eu
BIN=${1:-target/release/herdr}; OUT=.audit/out; BASE=.audit/baseline; mkdir -p "$OUT"

otool -L "$BIN" | tail -n +2 | awk '{print $1}' | sort > "$OUT/otool-L.txt"
nm -u -j "$BIN" | sort > "$OUT/nm-u.txt"
dyld_info -imports "$BIN" > "$OUT/dyld-imports.txt" 2>/dev/null || true
grep -E '_Sec(Item|Keychain|Access|Trust|Key)|_LA(Context|Policy)|_SSLCreate|_dlopen|_dlsym|_AXIsProcessTrusted|_CGWindowList|_CGDisplayCreateImage|_IOHIDRequestAccess|_AVCaptureDevice|_CLLocationManager|_SecCode|_SecTask|_ptrace|_task_for_pid|_csops|_posix_spawn|_execve|_system$|_popen' \
  "$OUT/nm-u.txt" > "$OUT/nm-flagged.txt" || true
otool -oV "$BIN" | grep -E 'name 0x|__objc_classrefs' | sort -u > "$OUT/objc-refs.txt" || true
strings -n 6 "$BIN" | grep -E '^(SecKeychain|SecItem|LAContext|NSWorkspace|NSPasteboard|NSAppleScript|CGWindow)' | sort -u > "$OUT/objc-strings.txt" || true
strings -n 8 "$BIN" | grep -oE 'https?://[A-Za-z0-9._/-]+' | sort -u > "$OUT/urls.txt"
strings -n 8 "$BIN" | grep -E '^(/usr/bin/|/bin/|osascript|open$|pbcopy|pbpaste|launchctl|afplay|terminal-notifier|ssh|scp|git|curl|sh -c)' | sort -u > "$OUT/exec-strings.txt"
codesign -dvvv "$BIN" 2> "$OUT/codesign.txt" || true
codesign -d --entitlements :- "$BIN" > "$OUT/entitlements.plist" 2>/dev/null || true
cargo audit bin "$BIN" > "$OUT/audit-bin.txt" || true

for f in otool-L nm-flagged objc-refs objc-strings urls exec-strings entitlements.plist; do
  diff -u "$BASE/$f"* "$OUT/$f"* || echo "CHANGED: $f"
done
```

Expected baseline: `urls.txt` contains only `herdr.dev`, `github.com`, `formulae.brew.sh` and documentation URLs; `otool-L.txt` lists libSystem, CoreFoundation, Carbon and libobjc; `nm-flagged.txt` is empty apart from `posix_spawn`/`execve` from std and possibly `dlopen`/`dlsym` from std weak lookups. Record and accept on first run.

### Runtime observation session (manual, about ten minutes, needs root and Full Disk Access)

```bash
# terminal 1: spawns, file opens, unix-socket connects
sudo eslogger exec fork exit open create rename unlink uipc_connect uipc_bind \
  | jq -c 'select((.process.executable.path|test("herdr")) or (.event.exec.target.executable.path? // "" | test("herdr")))' \
  > .audit/out/eslogger.jsonl

# terminal 2: TCC and keychain daemons (Endpoint Security has no event for these)
log stream --info --predicate '(process == "securityd" OR process == "secd" OR process == "tccd") AND eventMessage CONTAINS[c] "herdr"'

# terminal 3: network
nettop -P -L 0 -J bytes_in,bytes_out -p "$(pgrep -n herdr)"
lsof -nP -i -a -p "$(pgrep -d, herdr)"

# terminal 4: smoke test under a deny-by-default seatbelt
cat > .audit/herdr-smoke.sb <<'SB'
(version 1)
(deny default (with report))
(allow process-exec process-fork signal sysctl-read mach-lookup ipc-posix*)
(allow file-read*)
(allow file-write* (subpath (param "HOME_TMP")) (subpath "/private/tmp") (subpath "/dev"))
(allow network-outbound (remote tcp "*:443"))
(deny network-inbound)
(deny file-read* (subpath (string-append (param "HOME") "/Library/Keychains")))
(deny file-read* (literal (string-append (param "HOME") "/Library/Application Support/com.apple.TCC/TCC.db")))
SB
sandbox-exec -D HOME="$HOME" -D HOME_TMP="$HOME/.local/share/herdr" -f .audit/herdr-smoke.sb target/release/herdr server start
log stream --predicate 'sender == "Sandbox" AND eventMessage CONTAINS "herdr"'
```

Review rule: every exec target must be in the known set (`sh`, `bash`, `git`, `ssh`, `scp`, `curl`, `chmod`, `osascript`, `open`, `pbcopy`, `pbpaste`, `launchctl`, `afplay`, `terminal-notifier`, your configured agents); every outbound connection must be `curl` to `herdr.dev:443` or GitHub during `herdr update` (none at all once the fork disables both); no opens under `~/Library/Keychains`, the TCC database, `~/.ssh`, `~/.aws` or browser profiles; no TCC log lines.

### Linux equivalents

`strace -f -o .audit/out/strace.txt -e trace=%process,%network,%file target/release/herdr ...` then grep `execve(`, `connect(`, `openat(`. eBPF: `execsnoop-bpfcc`, `opensnoop-bpfcc -n herdr`, `tcpconnect-bpfcc`. Sockets: `ss -tunp | grep herdr`; nftables `log prefix "herdr-out "` rule on `meta skuid`. Sandbox: `bwrap --unshare-net --ro-bind / / --dev /dev --proc /proc --tmpfs "$HOME/.ssh" target/release/herdr ...` or `firejail --net=none --tracelog`. Static: `readelf -d`, `nm -D -u`, `objdump -T`, `strings`. Linux-only extra: cackle / `cargo acl` classifies per-crate net/fs/process/unsafe use and sandboxes build scripts and proc-macros with bubblewrap.

### Review-on-sync checklist (mandatory human read on every upstream merge)

- `build.rs`, `crates/ghostty-vt/build.rs`: code executed at build time; the latter picks the Zig invocation and link paths.
- `.cargo/config.toml`, `rust-toolchain.toml`, `justfile`, `.githooks/`, `scripts/*.sh`, `scripts/*.py`: rustc-wrapper, runner, linker or env injection.
- `Cargo.toml`, `crates/ghostty-vt/Cargo.toml`, `Cargo.lock`: new crates, features, `[patch]` entries; `source = "git+"` must never appear.
- `vendor/libghostty-vt/build.zig`, `build.zig.zon`, `build.zig.zon.nix`, `pkg/*/build.zig.zon`, `vendor/libghostty-vt.vendor.json`, `vendor/patches/`, `vendor/portable-pty/`: new fetch URLs or hashes, build steps, patch content.
- `src/noninteractive_process.rs`: the only curl call site and shared spawn helper.
- `src/update.rs`, `src/detect/manifest_update.rs`, `src/detect/manifests/`: remote fetch surfaces.
- `src/platform/macos.rs`, `src/platform/macos/`, `src/platform/linux*.rs`, `src/platform/unix_common.rs`, `src/platform/ssh_agent.rs`, `src/platform/remote_bridge.rs`: FFI, frameworks, external spawns.
- `src/integration/` and its `assets/`: writes into other agents' config files.
- `src/app/api/plugins/`: plugin execution and environment.
- `src/client/mod.rs`, `src/client/endpoint/`, `src/protocol/`, `src/remote/`: what a remote endpoint can make the local client do.
- `crates/ghostty-vt/src/bindings.rs`, `crates/ghostty-vt/src/lib.rs`: about 480 unsafe sites; diff the count and any new `extern` declarations.
- `.github/workflows/`, `distribution/`, `packaging/`, `nix/`, `flake.nix`, `flake.lock`, `assets/`: CI, installers, pinned inputs, binary blobs (`file` each new one).

Diff heuristics for the sync range `R=<last-sync>..HEAD`: `git diff --numstat $R | awk '$1=="-"'` (binaries), `git diff $R | grep -nE '^\+.*[A-Za-z0-9+/=_-]{120,}'` (opaque tokens), `git diff $R | grep -nE '^\+.*include_(bytes|str)!'`, `git diff $R | grep -nE '^\+.*(proc_macro|rustc-wrapper|runner *=|linker *=|RUSTFLAGS|\[patch|\[replace)'`, and a short entropy script over added lines longer than 80 chars (threshold about 5.0 bits/char), run with `python3 -I`.

### just recipes (sketch)

```make
audit-fast:                      # every build; blocks
    cargo deny --locked check
    cargo audit --deny warnings
    cargo vet
    cargo tree --locked -e normal,build --prefix none | sort -u > .audit/out/deps.txt && diff .audit/baseline/deps.txt .audit/out/deps.txt
    CLIPPY_CONF_DIR=.audit cargo clippy --all-targets --locked --message-format=short -- -W clippy::disallowed_methods -W clippy::disallowed_macros -W clippy::undocumented_unsafe_blocks -W unsafe_code 2>&1 | grep -E 'warning: ' | sort > .audit/out/clippy-audit.txt && diff .audit/baseline/clippy-audit.txt .audit/out/clippy-audit.txt
    grep -rc 'unsafe' --include='*.rs' src crates | grep -v ':0$' | sort > .audit/out/unsafe-counts.txt && diff .audit/baseline/unsafe-counts.txt .audit/out/unsafe-counts.txt

audit-binary: build              # every build; blocks on diff
    scripts/audit_post_build.sh target/release/herdr

audit-sync last_sync:            # every upstream merge; 5 to 20 min
    gitleaks git --log-opts="{{last_sync}}..HEAD" .
    trufflehog git file://. --since-commit {{last_sync}} --only-verified --fail
    osv-scanner scan source -L Cargo.lock
    cargo supply-chain publishers > .audit/out/publishers.txt
    cargo geiger --locked --output-format Ascii > .audit/out/geiger.txt || true
    semgrep --config p/rust --config p/0xdea --config .audit/semgrep --metrics=off --error src crates vendor/libghostty-vt/pkg/simdutf vendor/libghostty-vt/pkg/wuffs vendor/libghostty-vt/pkg/highway
    zizmor --min-severity medium .github/
    just maintenance-test

audit-deep:                      # weekly or when unsafe/FFI/vendor changed; 30 to 60 min
    codeql database create .audit/codeql-db --language=rust --build-mode=none --source-root . --overwrite
    codeql database analyze .audit/codeql-db codeql/rust-queries:codeql-suites/rust-security-extended.qls --format=sarif-latest --output=.audit/out/codeql.sarif
    LIBGHOSTTY_VT_OPTIMIZE=ReleaseSafe cargo +nightly careful test
    RUSTFLAGS=-Zsanitizer=address cargo +nightly test -Zbuild-std --target aarch64-apple-darwin --lib

audit-accept:                    # after human review
    cp .audit/out/{deps,clippy-audit,unsafe-counts,otool-L,nm-flagged,objc-refs,objc-strings,urls,exec-strings}.txt .audit/baseline/
```

Build with `cargo auditable build --release --locked` so `cargo audit bin` and osv-scanner can read the dependency list from the binary. `nix build --rebuild` on the flake is the cheapest "did my toolchain inject something" check, since it pins Zig and the zon dependencies.

### Considered and rejected

cargo-crev (web of trust needs bootstrapping; cargo-vet with imported audits covers more), cargo-scan (research tool), Miri (FFI mode is unsound by design and most tests reach libghostty), ThreadSanitizer (false positives with uninstrumented Zig), clang-tidy on vendored C++ (no `compile_commands.json` from Zig; the vendored code is upstream-maintained), Little Snitch (LuLu plus nettop suffices), Trivy/Grype (nothing over cargo-audit plus osv-scanner), App Sandbox entitlements (not applicable to an unsigned CLI), SBOM generation (only useful as input to another scanner).

Not verified this session: full clippy lint group names beyond the six checked; cargo-deny `[bans.build]` key names; whether Zig 0.16 enables UBSan-trap for C/C++ in ReleaseSafe; Cargo `trim-paths` stabilization status; Objective-See tool behaviour on macOS 26; `eslogger` event names other than exec/fork/exit (run `eslogger --list-events`); whether cackle needs nightly; whether `cargo careful` composes with nextest.
