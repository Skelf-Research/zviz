# Release Process

How ZViz releases are made.

## Version Scheme

`MAJOR.MINOR.PATCH`

- MAJOR: Breaking changes
- MINOR: New features
- PATCH: Bug fixes

## Release Steps

1. Update version in `src/main.zig`
2. Update CHANGELOG.md
3. Create git tag
4. GitHub Actions builds releases
