# Project Guidelines

## Environment

All compilation and testing must happen on the remote server via SSH, NEVER attempt local compilation (macOS lacks required kernel headers and UADK libraries).

## Git Safety

- When pushing to GitHub or creating PRs, always verify the remote URL points to the user's fork (IAMHCHCH/linux or IAMHCHCH/zswap-benchmark) and NEVER target torvalds/linux or any upstream repo.
- Before starting a commit, check git status for in-progress rebases, merges, or cherry-picks. If a rebase is in progress, either complete or abort it before committing.

## Editing Practices

When performing multi-file refactors that move or restructure code, apply changes incrementally and verify file integrity after each batch of edits rather than making all edits at once.

## Project Context

For UADK/HiSilicon ZIP driver work: the target hardware device is hisi_zip. Use perf_mode parameter for performance benchmarks. LZ4 lz77_only mode and zstd sequence producer API are both supported paths.
