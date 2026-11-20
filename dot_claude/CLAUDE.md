# How we work (all projects)

- GitHub is the remote of record; use `gh`. The issue tracker is the source of truth for task status and acceptance criteria. Before starting tracked work, read the issue, its comments, and its artifacts (`gh issue artifact list N`). They can be newer than the repo's docs.
- Org conventions live in `The-HOLE-Foundation/github-templates` under `docs/conventions/`. A repo's own `AGENTS.md`/`CLAUDE.md` overrides them.
- One issue per branch, one branch per PR. A PR says `Closes #N`, and its body lists what you did not run.

## Issue artifacts (`gh issue artifact`, preview)

Versioned Markdown/HTML docs and links, scoped to one issue.

- An issue's plan or hand-off goes in an artifact, edited in place. Comments are for events.
- Never copy a shared doc (roadmap, spec) onto issues. Attach a link artifact to its `blob/main/...` URL.
- What you read is a snapshot and nothing pushes updates. Re-read before acting on it later, and check `updatedAt`.
- Edits are last-write-wins. Before you replace one, check `view` for a version newer than the one you read.
