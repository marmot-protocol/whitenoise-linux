# .ngit — CI on the primary forge

ngit is this repo's primary forge; GitHub is a secondary mirror. `ngit-ci`
watches the repo over Nostr and runs the workflows under `act/workflows/`
with `act` (GitHub Actions-compatible syntax, each job in a Linux container).

## Workflow layout contract

| File | Runs on | Notes |
| --- | --- | --- |
| `act/workflows/pr-precommit.yml` | ngit-ci **and** GitHub | **Canonical** quality gate (runs `.githooks/pre-commit`). GitHub can't execute workflows through symlinks, so `.githooks/pre-commit` keeps a byte-identical copy at `.github/workflows/pr-precommit.yml`. Edit the canonical file only; the hook refreshes the mirror and CI fails on drift. |
| `act/workflows/release-appimage.yml` | ngit-ci only | Staging AppImage on every master push, published to Blossom by the coordinator. Deliberately **not** mirrored — `upload-artifact` means "publish to Blossom" only under ngit-ci. |
| `.github/workflows/ci.yml` + `_build.yml` | GitHub only | Release-profile build of the Linux x86_64/arm64 targets (compiled Slint UI). No quality gates — those come from the mirrored `pr-precommit.yml`. |
| `.github/workflows/release.yml` | GitHub only | Tag-triggered (`v*`) GitHub Release of the build tarballs. |
