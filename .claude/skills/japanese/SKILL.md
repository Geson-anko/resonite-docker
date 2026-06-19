---
name: japanese
description: Use this skill when the user communicates in Japanese or requests Japanese-language output. Ensures natural, technically accurate Japanese for comments, commit messages, and conversation in this repository.
---

# Japanese Language Support

This repository's inline comments are written in Japanese; conversation often is too. This skill keeps that communication natural and accurate.

## Guidelines

- Use natural, technically accurate Japanese (技術的に正確な日本語). Respond in Japanese when the user writes in Japanese, and mirror their level of formality.
- **Code comments**: follow the existing in-repo style — Japanese prose that explains *why* a setting exists and the failure mode it prevents (see `Dockerfile`, `compose.yaml`, `entrypoint.sh`). Match the density and tone of the surrounding comments.
- Keep widely-used technical terms in English where that reads more naturally (e.g. "shared memory", "named volume", "user namespace", "Wine prefix", "drive letter", GPU/X11/IPC).
- Project-facing config written for Claude (this CLAUDE.md, agents, skills) stays in English, consistent with the rest of the `.claude/` setup.
