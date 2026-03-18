# Orion

OpenAPI-first CLI for humans and AI agents.

## Badges

![CI](https://github.com/michalwiacek/orion-cli/actions/workflows/ci.yml/badge.svg)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)

## Status

Actively developed. CLI flags and output format may still evolve as we harden workflows.

## Requirements

- Zig 0.15.x
- Ruby (used for YAML -> JSON conversion in OpenAPI parsing)

## Build and test

```bash
zig build
zig test src/openapi_loader_integration_test.zig
```

## Release

See:

- [CHANGELOG.md](./CHANGELOG.md)
- [RELEASE_CHECKLIST.md](./RELEASE_CHECKLIST.md)

## Install locally

```bash
./setup.sh
```

Manual alternative:

```bash
zig build install --prefix ~/.local
```

## Goals
- Operation‑first architecture
- OpenAPI as source of truth
- CLI usable by humans and AI agents
- Local‑first (works without SaaS/control plane)

## MVP flow

orion inspect <openapi-url-or-file>
orion list
orion describe <operation-id>
orion call <operation-id|url-or-path>
orion curl <operation-id|url-or-path>
orion config

## Structure

src/
  main.zig
  cli/
  commands/
  core/
  providers/
  openapi/
  engine/
  http/
  auth/
  config/
  render/

## Config

Config is loaded from two layers:

1. Global: `~/.config/orion/config.json` (or `$XDG_CONFIG_HOME/orion/config.json`)
2. Project: nearest `.orion/config.json` from current directory upward

Project config overrides global config.

Example:

```json
{
  "base_url": "https://api.example.com",
  "openapi_spec": "./openapi.yaml"
}
```

With `base_url` configured, you can call relative paths:

```bash
orion call /users
```

You can also call directly by OpenAPI operation id:

```bash
# examples below are illustrative and spec-agnostic
orion call get:/health
orion call get:/items/{id} --param id=123 --query limit=10
orion call post:/auth/register --body '{"email":"a@b.com","password":"x"}'
orion curl get:/items/{id} --param id=123 --query limit=10
orion curl get:/health -k
orion curl get:/health --pretty
orion curl get:/health -- --http1.1 --connect-timeout 5
```

Supported flags for `call`:
- `--param key=value` for `{path}` placeholders in operation paths
- `--query key=value` to append query params
- `--body @file.json|json` for request body (JSON)
- `--method METHOD` for direct URL/path mode (default `GET`)

`orion curl` supports the same flags and prints an equivalent `curl` command.
It also passes native curl flags (for example `-k`, `--insecure`) and supports explicit `--curl-flag FLAG`.
Use `--pretty` for multiline output and `--` to pass remaining args directly to curl.

## OpenAPI parsing (MVP)

`orion list` reads operations from configured `openapi_spec` (or `openapi.remote.yaml` by default).

`orion describe` expects an operation id in format:

```bash
<method>:<path>
```

Example:

```bash
orion describe get:/health
```

`describe` now shows: summary, headers, parameters, request body fields, request body schema summary, and responses.
It also resolves common `$ref` values from `components` (parameters, responses, request body schemas).
Response lines include content type and resolved response schema refs when available.
Supported ref forms include:
- local refs: `#/components/...`
- external file refs: `./common.yaml#/components/...`
- HTTP refs: `https://...#/components/...`
- escaped JSON Pointer tokens (`~0`, `~1`)
