---
name: code-review
description: Review priorities for zsh-boot-kit pull requests — where to spend scrutiny versus what to skip. Use for every PR review.
---

# Review priorities

Four small, coupled zsh modules in `lib/*.zsh`, each with 1:1 shellspec
coverage in `spec/*.sh`. CodeQL only scans `.github/workflows/*` (no shell
analyser exists); it never sees the zsh logic below, so review here is the
only structural check on it.

## Spend real attention here
- `lib/lazy-plugins.zsh` — stub re-dispatch order (function, then alias, then
  binary) and trigger-collision/clobber handling. 2 of the repo's 3 real
  bugfix/feature PRs landed here: #3 "make stubs work without the registry"
  and #2 the `_lazy_after_<plugin>` clobber hook. Skipping a dispatch branch
  or letting two plugins silently share a trigger is a real regression.
- `lib/outdated-banner.zsh` — interactive/TTY gating and the y/N upgrade
  prompt. The repo's other real fix (#6) was a piped-stdin bug in exactly
  this prompt.
- `lib/env-cache.zsh` — the pre-read trust check in `_env_cache_usable`
  (symlink rejected via `-L` *before* the `-f`/`-O` tests that would
  otherwise follow it) and the mode-0600 temporary-file replacement. This module caches
  secrets like `GITHUB_PAT` in plaintext by design; reordering those checks
  or writing through the rejected inode can expose secrets or overwrite a
  symlink target. Check both the exported value and the filesystem effects.

- Review local workflow changes, including reusable caller triggers,
  permissions, runner choices, and pinned revisions.

## Do not spend attention here

- Unchanged reusable workflow template content can be checked against its
  central source; review any local changes.
- `README.md` — documentation prose, no executable path.
- `LICENSE`, `.gitignore`, `.shellspec` — boilerplate config, nothing to
  review.

## Comment style
- One comment per real issue, not one per `lib/*.zsh` file it repeats in.
- Don't restate a shellspec failure the `shellspec` job already reports
  inline; a passing suite says nothing about untested edge cases, so silence
  from CI is not a reason to wave a change through unread.
