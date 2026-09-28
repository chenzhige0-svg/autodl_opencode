# Architecture

## Goals and non-goals

Goals: reliability, idempotency, maintainability and reproducibility with plain
Bash; safe recovery without destructive operations; clear reporting.

Non-goals: a framework, a daemon, or a replacement for OpenCode's own install
and auth flows. The toolkit orchestrates the official artifacts and mechanisms.

## Module responsibilities

```
setup.sh
  ├─ parses arguments, acquires the run lock, dispatches commands
  └─ deploy flow: dependencies → install → config → persistence → PATH → verify

lib/common.sh   Configuration contract (paths, env overrides, exit codes),
                logging + redaction, dry-run runner, atomic writes, backups,
                managed shell blocks, temp workspace, locking, platform helpers.
lib/detect.sh   Read-only probes: OS/arch/kernel, user/HOME/shell, tool versions,
                disk, AutoDL detection, OpenCode discovery + install method.
lib/mount.sh    Real mount verification and persistence store selection
                (fs / tmp / path / auto / none) with durability description.
lib/net.sh      Proxy sanity, DNS/HTTP probing with failure classification,
                bounded exponential-backoff retry.
lib/install.sh  Release download (official artifacts), validation, atomic install,
                package-manager install, explicit upgrade, install marker.
lib/path.sh     Managed rc-file blocks, /usr/local/bin shim, resolution checks
                (current, interactive, non-interactive), conflict listing.
lib/config.sh   Config location, persistence symlinking, generation/merge from
                environment, safe validation via the Python helper.
lib/doctor.sh   Findings with stable IDs, severity and auto-fixability.
lib/repair.sh   Bounded repairs: dependencies, PATH, binary, config, credential
                permissions, persistence. Skips anything it cannot prove safe.
lib/verify.sh   Binary, PATH, config, persistence, auth; exit 0/4/5.
lib/backup.sh   Config backups, separated credential backups, restore.
scripts/oc_config.py  JSON/JSONC validate/normalize/get/set/merge.
```

## Configuration contract

Every path is overridable through environment variables so the toolkit is
testable and adaptable:

| Variable | Default |
|---|---|
| `OPENCODE_INSTALL_DIR` | `$HOME/.opencode/bin` |
| `OPENCODE_BIN` | `$OPENCODE_INSTALL_DIR/opencode` |
| `OPENCODE_CONFIG_HOME` | `${XDG_CONFIG_HOME:-$HOME/.config}/opencode` |
| `OPENCODE_DATA_HOME` | `$HOME/.local/share/opencode` |
| `OPENCODE_CACHE_HOME` | `${XDG_CACHE_HOME:-$HOME/.cache}/opencode` |
| `OCDEPLOY_STATE_HOME` | `$HOME/.local/state/opencode-autodl` |
| `OCDEPLOY_BACKUP_DIR` | `$OCDEPLOY_STATE_HOME/backups` |
| `OCDEPLOY_LOG_DIR` | `$OCDEPLOY_STATE_HOME/logs` |
| `OPENCODE_PERSIST_MODE` | `auto` |
| `OPENCODE_PERSIST_DIR` | unset |
| `OPENCODE_INSTALL_METHOD` | `curl` |
| `OPENCODE_INSTALL_ATTEMPTS` | `3` |
| `OCDEPLOY_LOGIN_SHELL` | (auto-detected) |

Test-only hooks: `OCDEPLOY_TEST_MOUNTS` / `OCDEPLOY_TEST_UNMOUNTED`
(colon-separated paths forced mounted/unmounted).

## Exit codes

```
0 ok                1 error              2 usage
3 environment/network problem            4 installed, authentication required
5 verification failed                    6 manual action required (repair unsafe)
7 locked (another run in progress)
```

`verify` and `deploy` return `4` when the program is installed and working but
no credentials exist — installation succeeded, authentication is a separate step.

## Persistence model

Two directories are persisted by symlinking them into a store:

```
<store>/opencode/config  ←  ~/.config/opencode
<store>/opencode/data    ←  ~/.local/share/opencode   (contains auth.json)
```

`~/.cache/opencode` is intentionally **not** persisted (safe to regenerate).

Before replacing an existing directory with a symlink the toolkit:

1. verifies the store is a real mount and writable;
2. copies existing contents into the store **without clobbering**;
3. keeps the original directory as `<dir>.oc-backup-<timestamp>`;
4. only then creates the symlink.

If the store is not mounted the operation is refused; no same-named directory is
created on the system disk.

## Logging

Human-readable output goes to stderr; the same messages (redacted) and
structured JSON events are appended to
`$OCDEPLOY_LOG_DIR/opencode-autodl-<timestamp>.log`. The redactor removes API
keys, bearer tokens, cloud/GitHub tokens and credentials embedded in URLs or
`key=value` pairs (including proxy userinfo). `--json` mirrors events to stderr.

## Concurrency and interruption

A lock directory under `$OCDEPLOY_STATE_HOME/lock` guards modifying commands. A
stale lock (owning PID gone) is cleared; otherwise the run aborts with exit 7.
Installs download and stage in a private temp directory and move the validated
binary into place, so an interruption never leaves a half-installed binary or a
success marker for a failed install.

## Dependency policy

Only install what is actually required for the chosen method: `curl` installs
need `curl` + `tar`; npm/bun need their package manager. Node.js is **not**
installed for curl installs. Package-manager locks are waited on (bounded), never
deleted. No CUDA/PyTorch/Conda/system upgrades are performed.

## Verification status (honesty about the environment)

**Verified in this workspace** (Arch Linux under WSL2): Bash syntax; ShellCheck
warning-level; the full test suite (mocked `curl`) — detection, fresh install,
idempotency, PATH repair, config generation/repair, backup/restore, mount-aware
persistence, dry-run, CLI contracts, and fault injection (download failure,
broken binary recovery, missing auth → exit 4, unmounted store refusal, corrupt
config detection); `doctor` run read-only against the real host.

**Not verified here** (must be validated on a real AutoDL instance):

- a real GitHub release download (the sandbox network is restricted; the WSL host
  timed out mid-download). The code path is the same as the mocked one, but the
  live artifact/URL was not exercised end to end;
- real `root` behaviour: `/usr/local/bin` shim creation and `apt`/`dpkg`
  dependency installation;
- actual `/root/autodl-tmp` and `/root/autodl-fs` mounts (simulated via the test
  hooks);
- live provider API calls (`OPENCODE_LIVE_TEST=1`), which may cost money;
- the official installer's `--binary` and Windows code paths (not used by the
  default flow).

Treat these as the remaining risk surface and confirm them during the first real
AutoDL deployment.
