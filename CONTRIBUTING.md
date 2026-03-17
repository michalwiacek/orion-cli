# Contributing

Thanks for considering a contribution.

## Development setup

1. Install Zig `0.15.x`.
2. Clone the repo.
3. Run:

```bash
zig build
zig test src/openapi_loader_integration_test.zig
```

## Pull requests

1. Keep changes focused and small.
2. Add or update tests when behavior changes.
3. Update README/docs for user-facing changes.
4. Ensure `zig build` and tests pass locally.

## Code style

1. Prefer clear, straightforward Zig over clever abstractions.
2. Keep CLI behavior stable and backward compatible when possible.
3. Return user-friendly errors for common failure cases.
