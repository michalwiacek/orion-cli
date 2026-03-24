# Orion

Stop writing curl.

Use your API like this instead:

```bash
orion inspect openapi.yaml
orion list
orion call get:/users/1
```

Orion is a task-first CLI that turns your OpenAPI spec into a usable runtime.

![Orion CLI demo](./demo.gif)

---

## Why?

Working with APIs usually looks like this:

```bash
curl -X GET https://api.example.com/users/1 \
  -H "Authorization: Bearer ..." \
  -H "Content-Type: application/json"
```

You need to:
- remember endpoints
- construct requests manually
- guess payloads
- jump between docs and terminal

---

## Orion

```bash
orion inspect openapi.yaml
orion list
orion search users
orion call get:/users/{id} --param id=1
```

- operations instead of endpoints  
- OpenAPI as source of truth  
- no context switching  
- works locally  
- usable by humans and AI agents  

---

## Quickstart

```bash
git clone https://github.com/michalwiacek/orion-cli
cd orion-cli

./setup.sh

orion inspect openapi.yaml
orion list
```

Need full command and flag reference? See [docs/cli-reference.md](./docs/cli-reference.md).

---

## Core workflow

```bash
orion inspect <spec>
orion list
orion describe <operation-id>
orion call <operation-id>
```

---

## Examples

```bash
orion call get:/items/{id} --param id=123
```

```bash
orion call post:/auth/login \
  --body '{"email":"a@b.com","password":"x"}'
```

```bash
orion search users
```

```bash
orion describe get:/health
```

---

## Features

- OpenAPI parsing (local + remote)
- operation-first CLI
- request generation from schema
- history + rerun
- profiles and environments
- fuzzy search (`orion search`)
- curl export (`orion curl`)
- offline mode (cache)
- AI-native hooks (`--for-agent`, `plan`, `explain`)
- HTTP shortcuts (`orion get /health`, etc.)

---

## Philosophy

Orion is not a wrapper around curl.

It operates on a different level:

- curl → HTTP layer  
- Orion → operation layer  

Instead of thinking in endpoints and payloads,
you work with actions defined in OpenAPI.

---

## Install

### Option 1 (recommended)

```bash
./setup.sh
```

### Option 2 (manual)

```bash
zig build install --prefix ~/.local
```

---

## Requirements

- Zig 0.15.x  

---

## Configuration

Config is loaded from two layers:

1. Global: `~/.config/orion/config.json`  
2. Project: nearest `.orion/config.json`  

Project config overrides global config.

Example:

```json
{
  "base_url": "https://api.example.com",
  "openapi_spec": "./openapi.yaml"
}
```

With `base_url` configured:

```bash
orion call /users
```

---

## Calling APIs

You can call:

### by operation id

```bash
orion call get:/health
```

### with params

```bash
orion call get:/items/{id} --param id=123 --query limit=10
```

### with body

```bash
orion call post:/auth/register \
  --body '{"email":"a@b.com","password":"x"}'
```

---

## curl export

```bash
orion curl get:/items/{id} --param id=123
```

Supports:

```bash
--pretty
--output text|json
-- --http1.1 --connect-timeout 5
```

---

## Flags (core)

- `--param key=value` → path params  
- `--query key=value` → query params  
- `--body json|@file.json` → request body  
- `--dry-run` → show request without sending  
- `--output text|json` → machine-friendly output  

---

## Workflow commands

- `orion doctor` → validate config  
- `orion history` → list calls  
- `orion rerun <id>` → replay  
- `orion search <query>` → find operations  
- `orion example <operation-id>` → generate payload  
- `orion explain <operation-id>` → explain flow  
- `orion cache refresh` → refresh cache  
- `orion profile add/list/remove` → manage profiles  
- `orion use <profile>` → switch context  
- `orion current` → show active profile  

---

## OpenAPI parsing

`orion list` reads operations from configured spec.

`orion describe` expects:

```bash
<method>:<path>
```

Example:

```bash
orion describe get:/health
```

Supports:
- local refs (`#/components/...`)
- external file refs (`./common.yaml#...`)
- HTTP refs (`https://...`)
- JSON Pointer escapes (`~0`, `~1`)

---

## Status

Actively developed.

CLI flags and output format may still evolve.

---

## Vision

Orion is a foundation for:

- CLI-first API workflows  
- AI-assisted system interaction  
- local-first tooling  
- optional control plane in the future  

---

## Contributing

PRs welcome.

---

## License

MIT
