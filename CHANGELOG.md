# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog and this project follows Semantic Versioning (pre-1.0).

## [Unreleased]

### Added

- Operation-first CLI flow: `list`, `describe`, `call`, `curl`, `config`.
- Layered config support: global + project (`project` overrides `global`).
- OpenAPI loader with JSON and YAML support.
- `$ref` resolution for:
  - local refs (`#/...`)
  - external file refs (`./file.yaml#/...`)
  - HTTP refs (`https://...#/...`)
  - escaped JSON Pointer tokens (`~0`, `~1`)
- Schema summaries for `allOf`, `anyOf`, `oneOf`, `items`, `additionalProperties`.
- `api curl` with:
  - pass-through curl flags (for example `-k`)
  - `--curl-flag FLAG`
  - `--pretty`
  - `--` passthrough
- Open-source project docs and governance files:
  - `LICENSE`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`
  - GitHub Actions CI workflow

