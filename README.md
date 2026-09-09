# dbs-mcp installer

One-command installer for **dbs-mcp**, the Do Big Studios MCP server, for Cursor, Claude Code, Claude Desktop and Codex.

> You need to be in the Do Big Studios GitHub organisation. The installer asks you to sign in with GitHub; if it says your account can't see the repository, ask your team lead for an invite.

## Install

**Windows** (PowerShell):

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; irm https://raw.githubusercontent.com/Do-Big-Studios/dbs-mcp-install/main/install.ps1 | iex
```

**macOS / Linux:**

```sh
curl -fsSL https://raw.githubusercontent.com/Do-Big-Studios/dbs-mcp-install/main/install.sh | bash
```

Then restart Cursor / Claude / Codex. The server appears as `dbs`.

The installer sets up anything missing (git, bun), signs you in with GitHub, clones the private [dbs-mcp](https://github.com/Do-Big-Studios/dbs-mcp) repository to `~/.dbs-mcp`, and registers the server with every supported client it finds on your machine. Updates are automatic. Re-running the command is always safe.

## Choosing clients

By default it registers with whichever of these are installed:

| Client | Config it writes |
|---|---|
| Cursor | `~/.cursor/mcp.json` |
| Claude Code | `~/.claude.json` |
| Claude Desktop | `claude_desktop_config.json` |
| Codex (CLI, IDE extension, app) | `~/.codex/config.toml` |

To pick explicitly, set `DBS_MCP_CLIENTS` before the command, e.g. `cursor,codex` or `all`:

```powershell
$env:DBS_MCP_CLIENTS = "cursor,codex"; Set-ExecutionPolicy Bypass -Scope Process -Force; irm https://raw.githubusercontent.com/Do-Big-Studios/dbs-mcp-install/main/install.ps1 | iex
```

```sh
DBS_MCP_CLIENTS=cursor,codex bash -c "$(curl -fsSL https://raw.githubusercontent.com/Do-Big-Studios/dbs-mcp-install/main/install.sh)"
```

## Troubleshooting

- **"Your GitHub account cannot see Do-Big-Studios/dbs-mcp"**: you're not in the organisation yet. Accept the invite at [github.com/Do-Big-Studios](https://github.com/Do-Big-Studios) and re-run.
- **Wrong GitHub account**: re-run with `DBS_MCP_REAUTH=1` set (same way as `DBS_MCP_CLIENTS` above).
- **Client doesn't show `dbs`**: fully quit and reopen it, not just reload the window.

Everything else is documented in the private repository once you have access.

<details>
<summary>What the sign-in grants</summary>

GitHub device flow with the Do Big Studios OAuth app, scopes `repo` (clone and update the private repo) and `read:packages` (private `@do-big-studios` packages). If git already has working github.com credentials, only `read:packages` is requested. The token is stored in `~/.npmrc` and your git credential helper; revoke it under GitHub > Settings > Applications.

</details>

<details>
<summary>Manual install</summary>

Install [git](https://git-scm.com) and [Bun](https://bun.sh), put a GitHub token with `read:packages` in `~/.npmrc` (`//npm.pkg.github.com/:_authToken=TOKEN`), then:

```sh
git clone https://github.com/Do-Big-Studios/dbs-mcp.git ~/.dbs-mcp
cd ~/.dbs-mcp && bun install && bun run setup
```

</details>

Copyright (c) 2026 Do Big Studios. All rights reserved. See [LICENSE.txt](LICENSE.txt).
