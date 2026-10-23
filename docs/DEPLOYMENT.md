# Deployment guide

## 1. First deployment on a new AutoDL instance

```bash
# Put the toolkit on the instance
git clone <your-repo> ~/opencode-autodl
cd ~/opencode-autodl

# Optional: accelerate GitHub in mainland-China regions
source /etc/network_turbo

# Preview, then deploy
./setup.sh deploy --dry-run
./setup.sh
```

What happens:

1. **Detect** — OS, arch, user, tools, disks, AutoDL mounts, any existing OpenCode.
2. **Dependencies** — installs only what the chosen method needs (default `curl`
   needs `curl` + `tar`; Node.js is *not* required).
3. **Install** — if missing/broken, downloads the official release, validates the
   binary by running `--version`, and installs it atomically. A healthy install is
   left untouched.
4. **Config** — creates a minimal config only if none exists; never overwrites.
5. **Persistence** — offers to link config/data into a mounted store
   (`/root/autodl-fs`, else `/root/autodl-tmp`).
6. **PATH** — fixes resolution for current, interactive and non-interactive shells.
7. **Verify** — reports `complete`, `authentication required`, or `problems`.

Then authenticate once:

```bash
opencode auth login
# or: opencode  →  /connect
```

Confirm:

```bash
./setup.sh status
./setup.sh verify
```

## 2. Choosing a persistence mode

```bash
./setup.sh persist --persist fs      # /root/autodl-fs  (cross-instance, same region)
./setup.sh persist --persist tmp     # /root/autodl-tmp (instance data disk)
OPENCODE_PERSIST_DIR=/data/oc ./setup.sh persist --persist path
./setup.sh unpersist                 # move back to local directories
```

If the store is not mounted, `persist` fails with a clear message and never
creates a fake directory. See `docs/ARCHITECTURE.md` for durability per tier.

## 3. Upgrading OpenCode safely

The toolkit never upgrades implicitly.

```bash
./setup.sh update --check      # read-only: exit 10 when a newer release exists
./setup.sh update              # latest; no-op when already current
./setup.sh update 1.0.180      # or a specific version (a deliberate pin)
```

`update` asks the GitHub API for the newest tag and compares it with the
installed version numerically (`1.0.9 < 1.0.180`) before touching the network
again, so a scheduled update that has nothing to do performs no download. An
install that is *newer* than the published release is never downgraded.

## 3a. Following releases automatically

```bash
./setup.sh autoupdate on       # install the shell hook
./setup.sh autoupdate status   # enabled?, last check, log location
./setup.sh autoupdate off      # remove it
```

`autoupdate on` appends one marker-managed line to the login shell's rc files:

```sh
"<repo>/setup.sh" autoupdate run >/dev/null 2>&1 &
```

The worker is throttled to one check per `OPENCODE_AUTOUPDATE_INTERVAL` seconds
(default 24h) via `~/.local/state/opencode-autodl/autoupdate.stamp`, writes that
stamp before contacting the network (so failures do not retry on every shell),
and logs to `~/.local/state/opencode-autodl/logs/autoupdate.log` (through the
normal run log).

A shell hook is used instead of cron/systemd because AutoDL containers normally
run neither, and the system disk — which would hold a crontab — is reset on an
image change. The hook lives in `$HOME`, which survives restarts, or in the
persistent store when `persist` is active. If you need updates without an
interactive shell, use a timer from your own scheduler; the equivalent command
is `./setup.sh update --yes`.

A broken version can be rolled back by reinstalling a pinned version:

```bash
./setup.sh install --opencode-version 1.0.180 --force
```

Back up first if you have heavily customised configuration:

```bash
./setup.sh backup --with-credentials
```

## 4. Migrating / restoring configuration

### Same instance (after an image change)

If persistence is configured, simply re-deploy — config/data are picked up from
the store:

```bash
./setup.sh
```

### From a backup

```bash
./setup.sh backup --with-credentials --archive     # on the old instance
# copy the backup directory/archive to the new instance, then:
./setup.sh restore /path/to/backup --with-credentials
```

Credentials are only restored with `--with-credentials`, and are kept in a
separate `credentials/` folder inside the backup so they can be transferred
independently and permissioned correctly (`auth.json` → `600`).

### Across instances via file storage

Make `/root/autodl-fs` the store on both instances (same region):

```bash
# instance A
./setup.sh persist --persist fs
# instance B (same region)
./setup.sh deploy --persist fs -y
```

## 5. Diagnose and repair

```bash
./setup.sh doctor          # read-only; print stable finding IDs
./setup.sh repair          # bounded automatic fixes; may exit 6 for manual items
./setup.sh verify          # exit 0 ok, 4 needs auth, 5 failed
```

`repair` will not delete lock files, will not disable TLS, will not remove your
plugins or config directory, and will refuse to touch anything it cannot prove is
safe — listing the manual command instead.

## 6. Environment overrides

Copy values from `config/autodl.example.env` into your shell, or export inline:

```bash
export OPENCODE_INSTALL_METHOD=curl
export OPENCODE_PERSIST_MODE=fs
export OPENCODE_MODEL="anthropic/claude-sonnet-4-5"
./setup.sh
```

## 7. Running the automated tests

```bash
bash tests/run_tests.sh
```

The suite uses a temporary HOME and a mocked `curl`; it never touches the real
OpenCode installation or the network.
