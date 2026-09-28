# opencode-autodl

Idempotent, tested automation for deploying and recovering
[OpenCode](https://opencode.ai) on [AutoDL](https://www.autodl.com) GPU instances.

One command installs OpenCode, restores your configuration and credentials from a
persistent store, verifies the result, and — when something breaks — diagnoses and
safely repairs it. Re-running never breaks a healthy environment.

```bash
./setup.sh            # safe deploy: detect → install → configure → verify
```

---

## Why

On AutoDL the system disk (`/`) is reset whenever you change images, so
OpenCode, its config (`~/.config/opencode`) and its credentials
(`~/.local/share/opencode/auth.json`) disappear. This toolkit makes deployment
repeatable and keeps your configuration in the data disk
(`/root/autodl-tmp`) or cross-instance file storage (`/root/autodl-fs`).

What it does **not** do: it never silently overwrites your config, never disables
TLS to get past a network problem, never deletes lock files, never upgrades CUDA /
PyTorch / Conda, and never claims success for an interrupted install.

---

## Requirements

- Linux (AutoDL instances are Ubuntu/Debian-like, but any POSIX-ish Linux works).
- `bash` ≥ 4, `curl`, `tar`. Python 3 is recommended (used for safe JSON/JSONC merging).
- `root` for system-wide PATH fixes, dependency installation and credential
  permissions; everything else works as a normal user.
- No Node.js required for the default `curl` install method.

---

## Quick start (new AutoDL instance)

```bash
# 1. get the toolkit onto the instance (clone or copy the folder)
git clone <your-repo> ~/opencode-autodl && cd ~/opencode-autodl

# 2. (optional) speed up GitHub in mainland-China regions
source /etc/network_turbo

# 3. deploy
./setup.sh
```

The default `deploy` flow prints an environment summary, installs OpenCode if
missing, creates a minimal config if none exists, offers to persist your
config/data into a mounted store, fixes `PATH`, and verifies everything.

When it finishes it reports one of:

- **deployment complete and verified** — ready to use;
- **authentication still required** — program is installed, run
  `opencode auth login` or `/connect` in the TUI;
- **problems found** — run `./setup.sh doctor`.

Then, if you have not authenticated yet:

```bash
opencode auth login          # or run `opencode` and use /connect
```

---

## Commands

| Command | Description |
|---|---|
| `./setup.sh` | Safe default deploy (detect → install → configure → verify). |
| `./setup.sh install` | Install OpenCode only if missing (or broken). |
| `./setup.sh doctor` | Read-only diagnosis of environment, network, PATH, install, config, auth, persistence. |
| `./setup.sh repair` | Apply bounded automatic fixes for what `doctor` found. |
| `./setup.sh verify` | Verify the deployment (exit 4 = installed, auth pending). |
| `./setup.sh backup [--with-credentials] [--archive]` | Back up config (and optionally credentials). |
| `./setup.sh restore <dir> [--with-credentials]` | Restore a backup. |
| `./setup.sh update [version]` | Explicitly upgrade OpenCode. |
| `./setup.sh persist` / `unpersist` | Move config/data into / out of the persistent store. |
| `./setup.sh config` | Create/merge config from environment variables. |
| `./setup.sh status` | One-line status summary. |

Global flags: `--dry-run`, `--yes`, `--verbose`, `--json`, `--no-color`,
`--version`, `--help`.

Install/persistence flags: `--method curl|npm|bun|pnpm|auto`,
`--opencode-version V`, `--force`, `--persist auto|fs|tmp|path|none`,
`--persist-dir D`, `--config FILE`.

### Preview without changing anything

```bash
./setup.sh deploy --dry-run
```

---

## Configuration and credentials

The toolkit **never overwrites an existing config**. A config is only created
when none exists, and explicit overrides are merged on top of your file (your
keys win), after showing a diff and asking for confirmation.

Set overrides through environment variables (see `config/autodl.example.env`):

```bash
export OPENCODE_MODEL="anthropic/claude-sonnet-4-5"
export OPENCODE_PROVIDER="anthropic"
export OPENCODE_BASE_URL="https://api.anthropic.com/v1"
export OPENCODE_API_KEY_ENV="ANTHROPIC_API_KEY"   # referenced as {env:...}
./setup.sh config
```

Or authenticate interactively (recommended):

```bash
opencode auth login      # credentials land in ~/.local/share/opencode/auth.json
```

**Never commit API keys.** The toolkit references keys via `{env:VAR}`, redacts
secrets from all logs, and keeps sensitive credential backups separate from
ordinary config backups (`backup` excludes credentials unless
`--with-credentials` is passed).

---

## Persistence on AutoDL

`--persist` selects where config and data are stored:

| Mode | Location | Survives restart | Survives image reset | Survives release / cross-instance |
|---|---|---|---|---|
| `fs` | `/root/autodl-fs` (file storage) | yes | yes | yes (same region) |
| `tmp` | `/root/autodl-tmp` (data disk) | yes | yes | no |
| `path` | `$OPENCODE_PERSIST_DIR` | depends | depends | depends |
| `none` | system disk only | no | no | no |

`auto` (the default) prefers mounted file storage, then the data disk, and
**refuses** to persist if neither is actually mounted — it will not fabricate a
same-named directory on the system disk. The data disk is **not** a cross-instance
backup; use `backup`/`restore` or file storage for that.

Persistence is implemented with symlinks from the real config/data directories
into `<store>/opencode/{config,data}`. Existing data is merged (never clobbered)
and the original directory is kept as `<dir>.oc-backup-<timestamp>`.

---

## Safety properties

- **Idempotent**: a healthy install is left untouched; a second run does not
  re-download or reinitialise anything.
- **Atomic install**: download → extract → run `opencode --version` → move into
  place. A failed download leaves no binary and no success marker.
- **Bounded retries** with exponential backoff; failures are classified
  (DNS / TCP / TLS / HTTP 4xx / 5xx / proxy), not blindly retried.
- **Concurrency safe**: a lock prevents two runs from colliding; stale locks are
  detected and cleared only when the owning process is gone.
- **Reversible changes**: every shell-rc edit uses a marker-delimited managed
  block and is backed up first; config edits are backed up and diffed.
- **Read-only diagnosis**: `doctor` never mutates anything.

---

## Repository layout

```
setup.sh                 Unified entrypoint (argument parsing + orchestration)
lib/common.sh            Config contract, logging, redaction, dry-run, locking
lib/detect.sh            OS/user/tools/disk/OpenCode discovery (read-only)
lib/mount.sh             Real mount detection + persistence store selection
lib/net.sh               Network/proxy diagnostics + bounded retry
lib/install.sh           Download/validate/install/upgrade
lib/path.sh              PATH repair, managed blocks, system shim, conflicts
lib/config.sh            Config persistence, generation, safe JSON merge
lib/doctor.sh            Diagnostic checks and findings
lib/repair.sh            Bounded automatic repairs
lib/verify.sh            Post-deploy verification
lib/backup.sh            Config/credential backup and restore
scripts/oc_config.py     JSON/JSONC validate/normalize/get/set/merge
config/                  Non-secret templates + example env
tests/                   Dependency-free test suite + curl/opencode mocks
docs/                    Research record and architecture
examples/                AutoDL quick-start and provider examples
```

See `docs/ARCHITECTURE.md` for the design and `TROUBLESHOOTING.md` for the fault
knowledge base.

---

## Running the tests

```bash
bash tests/run_tests.sh
```

The suite is sandboxed (temporary `HOME`/state, mocked `curl`) and includes:
detection, install, idempotency, PATH repair, config generation/repair,
backup/restore, mount-aware persistence, fault injection, dry-run and CLI
contracts.

Static analysis (optional):

```bash
shellcheck -x -S warning setup.sh lib/*.sh tests/*.sh tests/mocks/*
```

---

## Verification status

| Area | Status |
|---|---|
| Bash syntax (`bash -n`) | verified |
| ShellCheck (`-S warning`) | verified, clean |
| Unit + integration tests (mocked network) | verified, 97 assertions / 10 suites |
| Dry-run makes no changes | verified |
| Config back-up/restore, credential separation | verified |
| Mount-aware persistence (refuses unmounted stores) | verified |
| Fault injection (download fail, broken binary, missing auth, corrupt config) | verified |
| `doctor` against a real Linux environment | verified (read-only) |
| Real GitHub download / real AutoDL instance / root system changes / live model calls | **not verified in this environment — see `docs/ARCHITECTURE.md`** |

---

## License

Provided as-is for use with AutoDL and OpenCode. Review before running on a
production instance.
