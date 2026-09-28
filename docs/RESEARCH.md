# Research record

This document records the facts the toolkit was built against, with sources.
Commands and paths are **not** taken from memory.

Last researched: 2026-09-28.

## OpenCode

### Installation (source: https://opencode.ai/docs/ and https://opencode.ai/install)

- Primary install: `curl -fsSL https://opencode.ai/install | bash`.
- Alternative package managers: `npm install -g opencode-ai`, `bun install -g opencode-ai`,
  `pnpm add -g opencode-ai`, `yarn global add opencode-ai`, `brew install anomalyco/tap/opencode`,
  Arch `pacman -S opencode`.
- The official installer:
  - installs to `$HOME/.opencode/bin/opencode`;
  - detects OS/arch (`linux-x64`, `linux-arm64`, `darwin-x64`, `darwin-arm64`, `windows-x64`);
  - adds a `-baseline` variant when AVX2 is unavailable and `-musl` on musl systems;
  - downloads `https://github.com/anomalyco/opencode/releases/{latest|download/v<ver>}/opencode-<target>.tar.gz`
    (`.zip` outside Linux);
  - requires `tar` on Linux, `unzip` elsewhere;
  - supports `VERSION` env var and `-v/--version`, `-b/--binary`, `--no-modify-path`;
  - modifies a shell rc file to add `$HOME/.opencode/bin` to `PATH`;
  - does **no** checksum/signature verification.
- This toolkit uses the same release artifacts but stages + validates + atomically installs.

### Paths (source: https://opencode.ai/docs/config/ , https://opencode.ai/docs/troubleshooting/)

| Purpose | Path |
|---|---|
| Global config | `~/.config/opencode/opencode.json` (or `.jsonc`) |
| TUI config | `~/.config/opencode/tui.json` |
| Data (incl. credentials) | `~/.local/share/opencode/` |
| Credentials file | `~/.local/share/opencode/auth.json` |
| Logs | `~/.local/share/opencode/log/` |
| Cache | `~/.cache/opencode` |
| Managed config (Linux) | `/etc/opencode/` |
| Agents/commands/plugins/skills | `~/.config/opencode/{agents,commands,modes,plugins,skills,tools,themes}/` |

### Configuration (source: https://opencode.ai/docs/config/ , /providers/)

- JSON and JSONC are both accepted. Config files are **merged**, not replaced.
- Precedence: remote → global → `OPENCODE_CONFIG` → project → `.opencode` dirs →
  `OPENCODE_CONFIG_CONTENT` → managed.
- Env vars: `OPENCODE_CONFIG`, `OPENCODE_CONFIG_DIR`, `OPENCODE_CONFIG_CONTENT`,
  `OPENCODE_TUI_CONFIG`, `XDG_CONFIG_HOME`.
- Provider options: `provider.<id>.options.baseURL`, `.apiKey`, `.headers`, `npm`, `models`,
  plus `blacklist`/`whitelist`. Model refs are `providerId/modelId`.
- Secrets can be referenced as `{env:VAR}` or `{file:path}` instead of hardcoding.
- Auth precedence (documented for Bedrock): env/`/connect` token over the credential chain.

### CLI (source: https://opencode.ai/docs/cli/)

- `opencode` (TUI), `opencode run`, `serve`, `auth login|list|logout`, `models`,
  `upgrade [version]`, `uninstall [--keep-config --keep-data --dry-run --force]`, `debug`.
- Global flags: `--version`, `--help`, `--print-logs`, `--log-level`, `--pure`.

### Network (source: https://opencode.ai/docs/network/)

- Respects `HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY`. `NO_PROXY` **must** include
  `localhost,127.0.0.1` to avoid the TUI↔local-server loop.
- Custom CA: `NODE_EXTRA_CA_CERTS=/path/to/ca.pem`.
- No provider-specific proxy option; use per-provider `options.baseURL`.

## AutoDL (source: https://www.autodl.com/docs/ and linked pages)

- SSH login user is `root`; `HOME=/root`.
- System disk: `/`, ~30 GB, local. Survives shutdown; included in images;
  **reset on image change**.
- Data disk: `/root/autodl-tmp`, ≥50 GB, local. Survives shutdown and image
  reset; **not** saved into images; **lost on instance release**; instance-local.
- File storage: `/root/autodl-fs`, network storage shared across instances in the
  **same region**; survives release; must be initialised per region in the console.
- Public dataset: `/root/autodl-pub` (read-only).
- GitHub/HuggingFace are often slow; `source /etc/network_turbo` sets `http_proxy`/
  `https_proxy` for GitHub/HuggingFace domains. pip/conda mirrors are configured in
  the web console; apt mirror docs were not found.
- Persistence summary:
  - shutdown/restart → everything preserved;
  - image change/reset → system disk reset, data disk + file storage kept;
  - release → instance disks cleared, file storage kept (same region);
  - cross-instance → only file storage.

## Consequences for this toolkit

- Config (`~/.config/opencode`) and data (`~/.local/share/opencode`, incl.
  `auth.json`) live on the **system disk** by default and are lost on image
  change. Persistence moves them to `/root/autodl-fs` (preferred) or
  `/root/autodl-tmp`.
- A mount must be verified (`/proc/self/mountinfo`, `mountpoint`, `findmnt`,
  device-id heuristic) before writing persistent data, because AutoDL directory
  names exist even when unmounted.
- The data disk is not cross-instance backup; durability differs per tier and is
  reported to the user.
- Because the user is root, `/usr/local/bin/opencode` is a sound way to make the
  CLI available to non-interactive shells without rc-file reliance.
