# Orion CLI Reference

This document is the command reference for `orion`.

## Command index

- `orion` (without args): interactive mode (TUI-lite preview)
- `orion list [--output text|json] [--offline]`
- `orion describe <operation-id> [--output text|json] [--for-agent]`
- `orion call <operation-id|url-or-path> [flags]`
- `orion curl <operation-id|url-or-path> [flags] [-- ...]`
- `orion config [--output text|json]`
- `orion doctor [--output text|json]`
- `orion history [--limit N] [--output text|json]`
- `orion rerun <history-id> [--dry-run] [--output text|json]`
- `orion profile list [--output json]`
- `orion profile add <name> [--base-url URL] [--spec PATH]`
- `orion profile remove <name>`
- `orion use <profile>`
- `orion current [--output text|json]`
- `orion search <query> [--limit N] [--output text|json]`
- `orion example <operation-id> [--mode minimal|full] [--format json|yaml] [--output text|json] [--for-agent]`
- `orion explain <operation-id> [--output text|json]`
- `orion cache refresh|show`
- `orion plan <goal text> [--output text|json]`
- `orion plugin list|install <name>|remove <name>`
- `orion interactive [operation-id]`
- HTTP aliases: `orion get|post|put|patch|delete|head|options|trace <path-or-url> [call flags]`

## Targets and IDs

- `operation-id` format used by Orion is `method:/path`, for example `get:/health`, `post:/auth/login`.
- `url-or-path` can be:
  - absolute URL, for example `https://api.example.com/users`
  - relative path, for example `/users` (requires `base_url` from config or OpenAPI server)
- Some commands (`call`, `search`, `plan`) can resolve fuzzy matches from OpenAPI operations.

## Global output modes

Many commands support:

- `--output text` (default)
- `--output json`

## Config resolution

Config is merged from two layers:

1. Global config: `~/.config/orion/config.json` (or `$XDG_CONFIG_HOME/orion/config.json`)
2. Project config: nearest `.orion/config.json` from current directory upward

Project config overrides global config.

Example config:

```json
{
  "base_url": "https://api.example.com",
  "openapi_spec": "./openapi.yaml",
  "current_profile": "dev"
}
```

Profiles are stored under `profiles` map entries in the same config file.

## Command details

### `orion list`

Syntax:

```bash
orion list [--output text|json] [--offline]
```

Behavior:

- default mode loads operations from resolved OpenAPI spec
- `--offline` reads `.orion/spec_cache.json`

Examples:

```bash
orion list
orion list --output json
orion list --offline
```

### `orion describe`

Syntax:

```bash
orion describe <operation-id> [--output text|json] [--for-agent]
```

Behavior:

- shows summary, method/path, headers, parameters, request body fields, responses
- `--for-agent` forces JSON output and includes extra hints
- if operation is missing, suggests a close match when possible

Examples:

```bash
orion describe get:/health
orion describe post:/auth/login --for-agent
```

### `orion call`

Syntax:

```bash
orion call <operation-id|url-or-path> [--param key=value] [--query key=value] [--body @file.json|json] [--method METHOD]
           [--use NAME] [--save NAME] [--example] [--dry-run] [--explain] [--output text|json]
           [--no-auto-body] [--no-body-cache] [--show-body-source]
```

Flags:

- `--param key=value`: substitute path placeholders (`{id}`)
- `--query key=value`: append query string params
- `--body @file.json|json`: request body JSON
- `--method METHOD`: override method for URL/path mode
- `--use NAME`: load preset from `.orion/presets/NAME.json`
- `--save NAME`: save current request as preset
- `--example`: force schema-generated body example
- `--dry-run`: print resolved request without sending
- `--explain`: print resolution/debug context
- `--no-auto-body`: disable auto body generation from schema
- `--no-body-cache`: disable reading/writing remembered body history
- `--show-body-source`: include source label (`explicit`, `cache`, `generated`, etc.)
- `--output text|json`: output format

Behavior notes:

- if target is fuzzy text (not `method:/path`, not URL/path), Orion may resolve best operation id
- body auto-fill order is explicit `--body` -> `--example` -> cached/generated from schema
- successful operation-id calls may update `.orion/body_history.txt`
- successful calls are appended to `.orion/call_history.jsonl`

Examples:

```bash
orion call get:/health
orion call get:/users/{id} --param id=1
orion call post:/auth/login --example --dry-run
orion call /users --method POST --body '{"name":"Ada"}'
orion call --use login_admin --dry-run --explain
```

### `orion curl`

Syntax:

```bash
orion curl <operation-id|url-or-path> [--param key=value] [--query key=value] [--body @file.json|json] [--method METHOD] [-k] [--curl-flag FLAG] [--pretty] [--output text|json] [-- ...]
```

Flags:

- supports `--param`, `--query`, `--body`, `--method`
- `--curl-flag FLAG`: append custom curl flag
- native curl flags are passed through (for example `-k`, `--insecure`)
- `--pretty`: multiline rendered command
- `--`: pass remaining args directly to curl command builder
- `--output text|json`

Examples:

```bash
orion curl get:/health
orion curl get:/offers/{id} --param id=123 -k
orion curl post:/auth/login --body '{"email":"a@b.com","password":"x"}' --pretty
orion curl get:/health -- --http1.1 --connect-timeout 5
```

### `orion config`

Syntax:

```bash
orion config [--output text|json]
```

Shows global path, project path (if found), and merged effective settings.

### `orion doctor`

Syntax:

```bash
orion doctor [--output text|json]
```

Checks:

- config discovery
- `base_url` presence
- resolved spec path
- spec parse status and operation count

### `orion history`

Syntax:

```bash
orion history [--limit N] [--output text|json]
```

Behavior:

- reads `.orion/call_history.jsonl` from nearest `.orion` directory upward
- IDs are reverse chronological, starting at `1` for newest

### `orion rerun`

Syntax:

```bash
orion rerun <history-id> [--dry-run] [--output text|json]
```

Behavior:

- replays request stored in call history
- `--dry-run` prints reconstructed request without sending

### `orion profile`

Syntax:

```bash
orion profile list [--output json]
orion profile add <name> [--base-url URL] [--spec PATH]
orion profile remove <name>
```

Notes:

- profile storage is written to project `.orion/config.json` when no project config exists yet
- `profile list` marks current profile with `*`

### `orion use`

Syntax:

```bash
orion use <profile>
```

Sets `current_profile` in writable config.

### `orion current`

Syntax:

```bash
orion current [--output text|json]
```

Prints active profile and effective `base_url` / `openapi_spec`.

### `orion search`

Syntax:

```bash
orion search <query> [--limit N] [--output text|json]
```

Behavior:

- scores by exact/substring matches in operation id, path, and summary
- returns highest score first

### `orion example`

Syntax:

```bash
orion example <operation-id> [--mode minimal|full] [--format json|yaml] [--output text|json] [--for-agent]
```

Flags:

- `--mode minimal|full`
- `--format json|yaml`
- `--output text|json`
- `--for-agent` (structured JSON with hints)

Behavior:

- generates sample payload from request-body fields
- fallback example when schema shape is unavailable

### `orion explain`

Syntax:

```bash
orion explain <operation-id> [--output text|json]
```

Returns workflow-oriented explanation (flow hint, input requirements, expected responses).

### `orion cache`

Syntax:

```bash
orion cache refresh
orion cache show
```

Behavior:

- `refresh` stores operations snapshot to `.orion/spec_cache.json`
- `show` prints cached JSON

### `orion plan`

Syntax:

```bash
orion plan <goal text> [--output text|json]
```

Behavior:

- ranks operations relevant to goal text
- text mode prints suggested `describe` and `call` sequence

### `orion plugin`

Syntax:

```bash
orion plugin list
orion plugin install <name>
orion plugin remove <name>
```

Current state:

- lightweight placeholder registry stored in `.orion/plugins.json`

### `orion interactive`

Syntax:

```bash
orion interactive [operation-id]
```

Behavior:

- prints top operations list (TUI-lite)
- with argument, runs `describe` for selected operation
- no argument: prints next suggested commands

## HTTP alias commands

Syntax:

```bash
orion get <path-or-url> [call flags]
orion post <path-or-url> [call flags]
orion put <path-or-url> [call flags]
orion patch <path-or-url> [call flags]
orion delete <path-or-url> [call flags]
orion head <path-or-url> [call flags]
orion options <path-or-url> [call flags]
orion trace <path-or-url> [call flags]
```

Behavior:

- aliases forward to `orion call`
- for non-URL targets, alias builds operation-like target (`get:/path`)
- for URL targets, alias forwards explicit `--method`

Examples:

```bash
orion get /health --dry-run
orion post /auth/login --example --dry-run
orion get https://api.example.com/health -k
```

## Project state files

Orion writes project-local state in nearest `.orion/` directory:

- `.orion/config.json`: project config and profiles
- `.orion/spec_cache.json`: offline operation cache
- `.orion/call_history.jsonl`: call history entries
- `.orion/body_history.txt`: remembered successful bodies for operations
- `.orion/presets/*.json`: named call presets (`--save`, `--use`)
- `.orion/plugins.json`: plugin placeholder registry

## Errors and diagnostics

Common diagnostics:

- `No OpenAPI spec configured...` -> set `openapi_spec` or place `openapi.remote.yaml`
- `Relative path or operation-id ... requires base_url ...` -> set `base_url` or define OpenAPI server URL
- `Operation not found...` + `Did you mean: ...` -> use suggested operation or run `orion list`
- `No offline cache...` -> run `orion cache refresh`

## Important note

`inspect` is referenced in some older docs/examples, but the command is not part of current `main.zig` command routing.
Use `config`, `list`, `describe`, `search`, and `call` as current entrypoints.
