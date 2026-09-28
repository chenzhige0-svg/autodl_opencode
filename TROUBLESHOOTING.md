# Troubleshooting & fault knowledge base

Run the diagnosis first; it is read-only:

```bash
./setup.sh doctor           # human-readable findings with stable IDs
./setup.sh doctor --verbose # include debug detail
```

Then apply the bounded automatic fixes:

```bash
./setup.sh repair
```

Every finding below lists its ID, symptoms, causes, what the toolkit can fix
automatically, how it verifies the fix, and what to do when it cannot.

---

## A. Network problems

### A1. DNS resolution fails — `NET002`/`NET003`
- **Symptoms**: download fails immediately; `Could not resolve host`; doctor
  reports `DNS resolution failed`.
- **Causes**: no resolver configured, blocked DNS, bad proxy.
- **Automatic fix**: none (installing a resolver is not safe to guess).
- **Manual**: `cat /etc/resolv.conf`, `getent hosts github.com`. On AutoDL, try
  `source /etc/network_turbo`, then re-run.
- **Source**: https://opencode.ai/docs/network/

### A2. GitHub / opencode.ai unreachable or slow — `NET002`/`NET003`
- **Symptoms**: connection times out or resets while downloading.
- **Causes**: regional throttling (common in mainland-China AutoDL regions).
- **Automatic fix**: bounded retries with exponential backoff; explicit hint.
- **Manual**: `source /etc/network_turbo` (AutoDL accelerator for GitHub), then
  `./setup.sh install`. Configure a proxy with `HTTPS_PROXY`/`HTTP_PROXY` and
  `NO_PROXY=localhost,127.0.0.1`.
- **Note**: TLS verification is **never** disabled to work around this.

### A3. TLS / certificate errors — `NET002`/`NET003`
- **Symptoms**: `SSL certificate problem`, `unable to verify the first
  certificate`.
- **Causes**: corporate MITM proxy, missing CA bundle, clock skew.
- **Detection**: classification `tls` in doctor.
- **Automatic fix**: none (we never bypass verification).
- **Manual**: install the CA (`apt-get install ca-certificates`), or point
  `NODE_EXTRA_CA_CERTS=/path/to/ca.pem`. Fix the clock with `date`.
- **Source**: https://opencode.ai/docs/network/

### A4. Proxy misconfiguration — `NET001`
- **Symptoms**: doctor warns *NO_PROXY does not include localhost*.
- **Cause**: the TUI talks to a local server; without `NO_PROXY` it loops
  through the proxy.
- **Automatic fix**: none; reported with the exact required value.
- **Manual**: `export NO_PROXY=localhost,127.0.0.1`.
- **Source**: https://opencode.ai/docs/network/

### A5. HTTP 403 / 404 / 429 / 5xx
- **Detection**: doctor classification by status code.
- **403**: rate limit / auth / blocked source — try the accelerator or the
  package-manager method (`--method npm`).
- **404**: wrong release/version — omit `--opencode-version` to use latest.
- **429**: rate limited — bounded retry; wait and re-run.
- **5xx**: server-side — bounded retry; if persistent, wait.

---

## B. Dependencies and system problems

### B1. Missing base tools — `ENV003`, `DEP001`
- **Symptoms**: `curl`/`tar` (or `node`/`bun`) not found.
- **Automatic fix**: `./setup.sh repair` installs only the tools the selected
  method needs, via the detected package manager, as root.
- **Verification**: the tool is re-probed after installation.
- **Manual**: `apt-get install -y curl tar ca-certificates`.
- **Guard**: Node.js is not installed for `curl` installs.

### B2. Package manager locked (apt/dpkg) — bounded wait
- **Symptoms**: `Could not get lock /var/lib/dpkg/lock-frontend`.
- **Automatic fix**: waits up to 120 s for the holder to finish, then reports.
- **Never**: lock files are not deleted. Deleting them can corrupt dpkg state.
- **Manual**: find the process (`fuser /var/lib/dpkg/lock-frontend`) and wait.

### B3. CPU architecture mismatch
- **Detection**: `oc_install_target` maps `uname -m` to `x64`/`arm64` and adds
  `-baseline` (no AVX2) / `-musl` (Alpine) variants.
- **Symptoms**: `Exec format error`, illegal instruction at startup.
- **Manual**: install the matching artifact; report unsupported arch to the user.

### B4. Missing shared libraries
- **Detection**: `repair` runs `ldd` on a broken binary and reports `not found`
  entries.
- **Automatic fix**: none (package names are distro-specific and unsafe to guess).
- **Manual**: install the reported `.so` packages, then re-run.

### B5. Out of disk space — `ENV004`
- **Symptoms**: install fails; doctor reports low free space.
- **Automatic fix**: none; refuses to install below ~200 MB free.
- **Manual**: free space under `$HOME` (or move config to a persisted store).

---

## C. OpenCode configuration and credentials

### C1. Config file missing — `CFG001`
- **Automatic fix**: `./setup.sh config` (or `deploy`) creates a minimal config
  **only** when none exists.
- **Manual**: `opencode` then `/connect`.

### C2. Invalid JSON / JSONC — `CFG002`
- **Symptoms**: `ProviderInitError`; doctor reports config invalid.
- **Automatic fix**: `repair` first backs up the file, then tries to normalize
  (strip comments/trailing commas). If normalization fails it quarantines the
  file as `opencode.json.oc-invalid-<ts>` and regenerates a minimal config.
  **The original is never deleted.**
- **Verification**: the config is re-validated after the fix.
- **Manual**: inspect the quarantine copy and merge your keys back.

### C3. Wrong provider / model id — `CFG003`
- **Symptoms**: `ProviderModelNotFoundError`.
- **Cause**: model refs must be `providerId/modelId`.
- **Automatic fix**: none (cannot guess intent).
- **Manual**: `opencode models`, then set `model` correctly; see
  https://opencode.ai/docs/troubleshooting/.

### C4. API key missing or invalid — `CFG004`
- **Symptoms**: provider authentication errors at runtime.
- **Detection**: absence of `~/.local/share/opencode/auth.json`.
- **Behaviour**: this is **not** an install failure. `verify`/`deploy` return
  exit code 4 and report “authentication still required”.
- **Manual**: `opencode auth login`, or `/connect` in the TUI, or set provider
  `options.apiKey` to `{env:VAR}`.
- **Source**: https://opencode.ai/docs/providers/

### C5. Credential file permissions too open — `CFG005`
- **Automatic fix**: `chmod 600 ~/.local/share/opencode/auth.json`.
- **Guard**: on filesystems that cannot store Unix modes (some network storage),
  the check is skipped rather than reported as fixed.

### C6. Cache corruption — `CFG006`, `AI_APICallError`
- **Automatic fix**: `repair` moves `~/.cache/opencode` aside
  (`*.oc-cache-<ts>`) so it regenerates. Cache is never persisted/backed up.
- **Source**: https://opencode.ai/docs/troubleshooting/ (clear `~/.cache/opencode`).

### C7. Plugin conflicts
- **Symptoms**: startup failure after adding a plugin.
- **Automatic fix**: none (removing user plugins could hide intent).
- **Manual**: isolate by temporarily moving `~/.config/opencode/plugins/` or the
  `plugin` array entry. `repair` never mass-deletes the config directory for this.

---

## D. AutoDL environment problems

### D1. OpenCode lost after image change/reset — `OC001`
- **Cause**: the system disk (`/`) is reset on image change; `~/.opencode`,
  `~/.config/opencode` and `~/.local/share/opencode` are on it.
- **Automatic fix**: re-run `./setup.sh` — it reinstalls and restores from the
  persistent store and/or a backup.
- **Prevention**: persist to `/root/autodl-fs` (see `./setup.sh persist`).

### D2. Data disk not mounted — `ENV005`, `PERSIST001`
- **Symptoms**: `/root/autodl-tmp` exists but is a plain directory; persistence
  is refused.
- **Automatic fix**: none — the toolkit **refuses** to create a fake store.
- **Manual**: check the instance data disk in the AutoDL console.
- **Source**: https://www.autodl.com/docs/local_disk/

### D3. File storage unavailable — `ENV006`, `PERSIST001`
- **Causes**: region not initialised; instance booted before initialisation;
  mount disabled in console; subaccount without permission.
- **Automatic fix**: none.
- **Manual**: initialise file storage for the region, then reboot the instance,
  then `./setup.sh persist`.
- **Source**: https://www.autodl.com/docs/fs/

### D4. Permissions after restore
- **Symptoms**: restored files owned by another user, or `auth.json` too open.
- **Automatic fix**: credential permissions are corrected; config restores keep
  the existing owner where possible.
- **Manual**: `chown -R "$(id -un):$(id -gn)" ~/.config/opencode`.

### D5. PATH not effective in a new session — `PATH001/002/003`
- **Symptoms**: works in one shell, not in a new SSH session or script.
- **Automatic fix**: `repair` writes a marker-managed block to the login shell's
  rc file(s) (backed up first) and, as root, creates
  `/usr/local/bin/opencode -> ~/.opencode/bin/opencode` so non-interactive shells
  also work.
- **Verification**: resolution is checked in the current, interactive and
  non-interactive shells.
- **Manual**: `export PATH="$HOME/.opencode/bin:$PATH"`.

### D6. Multiple OpenCode installations — `PATH004`
- **Symptoms**: an unexpected version runs.
- **Detection**: all `opencode` binaries on `PATH` and well-known locations are
  listed.
- **Automatic fix**: none (we do not delete other installs).
- **Manual**: remove the unwanted install or reorder `PATH`.

### D7. Low disk space on the system disk — `ENV004`
- **Automatic fix**: none.
- **Manual**: move config/cache to a persisted store or free space. Note the
  system disk is only ~30 GB on AutoDL.

---

## Recovering from a bad state

```bash
./setup.sh doctor                       # what is actually wrong
./setup.sh repair                       # bounded fixes
./setup.sh backup --with-credentials    # snapshot config + credentials
./setup.sh restore <backup-dir> --with-credentials
```

If `repair` exits `6`, it found something it will not touch automatically; the
summary lists the exact command to run by hand. Nothing destructive happens
without a backup.
