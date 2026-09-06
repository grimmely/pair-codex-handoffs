# Pair Codex Handoffs

Private, Git-backed async handoffs for two Codex collaborators.

One handoff contains readable context, an importable Codex session, and source
state needed to continue work after a sleep-cycle handoff.

## Requirements

- Fish 4+
- Git
- `tar` with gzip support
- Node.js (already required by `codex-session-exporter`)
- GitHub CLI: `gh auth login`
- `codex-session-exporter` in `PATH`

The sender verifies that `origin`, every `origin.pushurl`, and GitHub privacy
all resolve to `grimmely/pair-codex-handoffs` before exporting anything.
The handoff remote must use SSH or HTTPS; plaintext HTTP is rejected.

## Send a handoff

From this repository's root:

```fish
fish scripts/handoff.fish \
  --handoff-repo /path/to/pair-codex-handoffs \
  --source-repo /path/to/project \
  --codex-home /path/to/codex-home \
  --note "Continue the payment retry work."
```

The script selects the newest local Codex session whose resolved working
directory is the source project or a directory beneath it. To choose one
explicitly, pass its ID; the same project-boundary check still applies.

```fish
fish scripts/handoff.fish \
  --handoff-repo /path/to/pair-codex-handoffs \
  --source-repo /path/to/project \
  --codex-home /path/to/codex-home \
  --session-id <session-id>
```

Use one shared handoff-repository branch. The first handoff publishes its
current branch and configures its upstream automatically.

Each handoff is one Git commit:

```text
handoffs/YYYY/MM/<timestamp>-<session-id>/
  HANDOFF.md
  transcript.md
  session.codex-session.tar.gz
  source-status.txt
  source.patch              # only when tracked source changes exist
```

`source.patch` includes tracked staged and unstaged changes, including an
unborn source repository. Untracked files are only listed in
`source-status.txt`.

Source remote metadata has credentials, query strings, and fragments removed
before it is written to `HANDOFF.md`.

## Receive a handoff

Pull the shared handoff branch, inspect `HANDOFF.md`, then run from this
repository's root:

```fish
fish scripts/receive.fish \
  --handoff-dir /path/to/pair-codex-handoffs/handoffs/YYYY/MM/<id> \
  --target-cwd /path/to/project \
  --codex-home /path/to/codex-home
```

Before import, the receiver copies the archive to a private temporary
directory and accepts only the exact expected bundle tree:

- regular files and directories only; no links or special files
- fewer than 100 MiB compressed and unpacked
- manifest rebuilt with fixed internal file paths
- rollout path restricted to a matching session ID under Codex session roots
- session-ID collisions refused rather than replacing a local session

It never checks out a commit or applies `source.patch` automatically. Review
the patch, then run `git apply --check` before any manual apply.

`--codex-home` selects the Codex session store. It defaults to `CODEX_HOME`
when set, otherwise `~/.codex`. Omit it for that default. Pass it explicitly
when running from a shell outside the Codex process, such as Pair Codex Sessions.

## Storage and privacy

Bundles use `tar.gz`, then remain plaintext in Git.

- Keep this repository private.
- Never hand off credentials you would not commit.
- Warn above 50 MiB total handoff size; stop at 100 MiB.
- Git history retains past bundles after deletion.
- Compression reduces space; it does not encrypt content.
