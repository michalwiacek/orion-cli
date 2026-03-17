# Release Checklist

## Before tagging

1. Ensure local branch is up to date and CI is green.
2. Run:

```bash
zig build
zig test src/openapi_loader_integration_test.zig
```

3. Update [CHANGELOG.md](/Users/michal/code/apicli-skeleton/CHANGELOG.md):
   - move relevant entries from `Unreleased` into the new version section.
4. Confirm README examples still match current CLI behavior.
5. Confirm no local secrets or local config files are tracked.

## Tag and release

1. Create a version tag (example):

```bash
git tag v0.1.0
git push origin v0.1.0
```

2. Create a GitHub Release for the tag.
3. Paste release notes from the changelog.
4. Attach binaries if publishing artifacts.

## After release

1. Verify installation instructions from a clean environment.
2. Open a new `Unreleased` section in changelog (if needed).
