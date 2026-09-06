---
name: handoff
description: "Send, receive, inspect, or configure private async pair-programming handoffs. Use when a collaborator wants to continue work across a handoff, share a session, or change private handoff storage."
---

# Handoff

Use this skill for private, Git-backed async pair handoffs. The public tool
never stores session material; bundles go only to user-configured private
storage. Use storage shared only with trusted pair writers: conversation
content remains collaborator-provided data.

Current supported harnesses:

```text
codex
```

Resolve the Pair Codex home as `PAIR_CODEX_HOME`, then `CODEX_HOME`, then
`$HOME/.pair-codex`. The dispatcher is:

```fish
fish "<pair-codex-home>/tools/pair-codex-handoffs/scripts/pair-handoff.fish"
```

For a standalone checkout, use its `scripts/pair-handoff.fish` path instead.

## Help

For `handoff help`, return this command menu without running a command or
changing state:

- `handoff send` — create and share a handoff from the current project.
- `handoff receive <share URL|latest>` — inspect and import a received handoff.
- `handoff status` — show storage configuration and health.
- `handoff configure` — select or replace the private storage repository.

For command-line help, run:

```fish
fish "<dispatcher>" help
```

## Configure

For `handoff configure`, first explain that the user must create a private
GitHub `owner/repo`, give their pair write access, and ensure
`gh repo view owner/repo` succeeds. It may be empty: configuration pushes one
empty `main` init commit. If it already has Git content, it must already default
to `main`; configuration never changes existing branch or content. Do not have
two people initialize the same storage repository concurrently.

Ask for the repository only when it is missing. Show the exact pending command
and explain that it validates, clones, and changes local configuration. Request
confirmation immediately before running it:

```fish
fish "<dispatcher>" configure --storage-repo "<owner/repo>"
```

Changing storage later is supported. It creates or reuses that repository’s
separate checkout; it never replaces an earlier checkout.

## Status

For `handoff status`, run:

```fish
fish "<dispatcher>" status
```

Return configured storage repository, local checkout health, and supported
harnesses. If storage is absent or unhealthy, offer `handoff configure`.

## Send

Only `codex` currently supports session export. For a send:

1. Resolve current Git root; ask for source path only if unavailable.
2. State selected source root, `codex` harness, and that tracked changes are
   captured as `source.patch` while untracked contents are excluded.
3. Ask for a concise sender note when missing.
4. Show the exact command and explain it exports, commits to private storage,
   and pushes a share URL. Request confirmation immediately before execution.
5. Run:

   ```fish
   fish "<dispatcher>" send --harness codex \
     --source-repo "<source-root>" --note "<sender-note>"
   ```

Add `--session-id "<id>"` only for an explicit user-supplied ID. Return the
script’s handoff directory and share URL.

## Receive

For a receive:

1. Accept a share URL, `handoffs/codex/...` path, or `latest`.
2. Resolve it only below configured `handoffs/codex`; reject absolute paths
   outside storage, `..` segments, and URLs outside configured storage.
   A commit URL must be reachable from storage `main`; import its exact
   committed bundle rather than a later version of that directory.
3. Inspect `HANDOFF.md` and source patch before import.
4. Resolve target Git root; ask for target path only if unavailable.
5. Show handoff identity, target root, and patch path. Request
   confirmation immediately before import.
6. Run:

   ```fish
   fish "<dispatcher>" receive --harness codex \
     --handoff "<shared-url-or-validated-handoff-path>" \
     --target-cwd "<target-root>"
   ```

The importer removes sender execution-policy metadata; approval and sandbox
settings remain those of the receiving Codex installation.

Never check out sender commits or apply `source.patch` automatically. Recommend
`git apply --check` before any manual patch application.
