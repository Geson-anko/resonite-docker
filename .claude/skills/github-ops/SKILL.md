---
name: github-ops
description: Use this skill when performing GitHub operations for this repo such as creating pull requests, writing commit messages, or managing issues. Covers branch/PR conventions and the commit style used here.
---

# GitHub Operations

GitHub workflow conventions for this repository.

## Commit Messages

- Conventional Commits: `type(scope): description` (`feat`, `fix`, `docs`, `refactor`, `chore`).
- Imperative mood, subject under ~72 chars. Match the existing history, e.g. `fix: give the container audio so Resonite no longer freezes on launch`.
- Because the value of this repo is in *why*, prefer commit bodies that explain the failure mode a change fixes, not just what changed.

## Pull Requests

- Branch from `main` with a descriptive name: `feat/`, `fix/`, `docs/`, `refactor/`.
- PR title follows Conventional Commits. Keep PRs focused — one logical change.
- In the description, state what changed, why, and **how it was verified** — include the GPU vendor tested on (NVIDIA / AMD / Intel).
- Never commit `.env` (it's gitignored and host-specific).

## Issues

- Label as `bug`, `enhancement`, or `documentation`. Reference issues in PRs with `Closes #123`.
- For launch-failure bug reports, ask for `./run.sh logs -f` output, the GPU vendor, and host distro/desktop session.
