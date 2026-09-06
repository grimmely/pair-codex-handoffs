# Pair Codex Handoffs

Public, Fish-based tooling for private async pair-programming handoffs.

The tool creates a readable work summary, a compressed resumable session, and
a source-state patch. It pushes those files only to **your private storage
repository** and returns a GitHub URL for your pair.

Use [Pair Codex Setup](https://github.com/grimmely/pair-codex-setup) for the
complete Codex pairing environment. This repository also works standalone and
ships a reusable `handoff` skill.

## Before starting

1. Create a **private** GitHub repository for handoff storage, initialized on
   `main`.
2. Give your pair collaborator write access to it.
3. Ensure its default branch is `main`.
4. Authenticate GitHub CLI so this succeeds:

   ```fish
   gh repo view OWNER/PRIVATE-HANDOFF-STORAGE
   ```

The tool refuses public repositories. Archives, transcripts, and patches are
plaintext in Git: compression saves space; it does not encrypt content.

## Install paths

### Complete Codex setup

```fish
curl -fsSL https://raw.githubusercontent.com/grimmely/pair-codex-setup/main/bootstrap.sh | bash
```

The installer asks for the private storage repository, validates it, installs
the tool and `handoff` skill, then configures the local storage checkout.

### Standalone tool

```fish
git clone https://github.com/grimmely/pair-codex-handoffs.git
cd pair-codex-handoffs
fish scripts/pair-handoff.fish configure \
  --storage-repo OWNER/PRIVATE-HANDOFF-STORAGE
```

Configuration is local. Change it later without replacing old checkouts:

```fish
fish scripts/pair-handoff.fish configure \
  --storage-repo OWNER/ANOTHER-PRIVATE-STORAGE
```

After pulling a newer public tool, explicitly refresh the copied global skill:

```fish
fish scripts/sync-handoff-skill.fish
```

It preserves the previous global skill below
the Pair Codex home (by default `$HOME/.pair-codex/handoff-skill-backups/`)
before publishing the refreshed one. Start a new Codex session after a first
install or skill refresh.

## Use from Codex

After Pair Codex Setup, choose `handoff` from Codex’s slash-command list or
type `$handoff`. Ask it to send, receive, inspect status, or configure storage.
It asks for confirmation immediately before cloning, importing, committing, or
pushing.

The skill is also available in [`skills/handoff`](skills/handoff). Another
harness can provide a thin native command adapter that calls the same Fish
dispatcher.

## Command line

```fish
# Show storage configuration and supported harnesses.
fish scripts/pair-handoff.fish status

# Create a handoff from the newest session in this project.
fish scripts/pair-handoff.fish send \
  --harness codex \
  --source-repo /path/to/project \
  --note "Continue the payment retry work."

# Receive a handoff from the GitHub commit URL shared by your pair.
fish scripts/pair-handoff.fish receive \
  --harness codex \
  --handoff https://github.com/OWNER/PRIVATE-HANDOFF-STORAGE/commit/COMMIT \
  --target-cwd /path/to/project
```

`send` uses the active `CODEX_HOME`, or `~/.codex` when unset. Add
`--codex-home /path/to/codex-home` for a shell outside that environment.

## Supported harnesses

| Harness | Session export and import | Native command |
| --- | --- | --- |
| Codex | Supported | `handoff` skill / `$handoff` |

The command surface is prepared for more harnesses. An added adapter owns only
its session export/import behavior and command syntax; storage, safety checks,
and Git publishing remain shared.

## Storage layout

```text
handoffs/
  codex/
    YYYY-MM-DD/
      <timestamp>-<session-id>/
        HANDOFF.md
        transcript.md
        session.codex-session.tar.gz
        source-status.txt
        source.patch                # only when tracked changes exist
```

Every handoff becomes one commit on `main`. The generated share URL points to
that commit in your private storage repository.

## Safety model

- Share storage only with trusted pair writers; imported conversation content is
  collaborator-provided data.
- Requires `fish`, `git`, `gh`, `tar`, Node.js, and `codex-session-exporter`.
- Validates configured storage remote, every push URL, private visibility, and
  `main` before sending or receiving.
- Refuses paths outside the selected harness directory.
- Receives commit URLs only from configured `main` history and materializes
  the exact committed bundle, never a later working-tree replacement.
- Warns above 50 MiB and refuses handoffs at 100 MiB.
- Validates the compressed bundle before import; refuses symbolic links,
  unexpected archive entries, unsafe paths, and existing session IDs.
- Strips sender approval, sandbox, permission, and network policy from an
  imported session; receiver policy remains local.
- Never checks out sender commits or applies `source.patch` automatically.

Review a patch before applying it:

```fish
git apply --check /path/to/source.patch
```
