# pair-codex-handoffs

Public, Fish-based tooling for private async pair-programming handoffs.

The tool creates a compressed resumable session and optional tracked-source
patch. It pushes those files only to **your private storage repository** and
returns a GitHub URL for your pair.

Use [pair-codex-setup](https://github.com/grimmely/pair-codex-setup) for the
complete Codex pairing environment. This repository also works standalone and
ships a reusable `handoff` skill.

## Before starting

1. Create a **private** GitHub repository for handoff storage. It may be empty.
2. Give your pair collaborator write access to it.
3. Authenticate GitHub CLI so this succeeds:

   ```fish
   gh repo view OWNER/PRIVATE-HANDOFF-STORAGE
   ```

When it observes no Git refs, configuration pushes one empty `main` commit.
If the repository already has Git content, the tool leaves it untouched and
requires `main` to be its default branch. Do not have two people initialize
the same storage repository concurrently.

The tool refuses public repositories. Archives and patches are plaintext in
Git: compression saves space; it does not encrypt content.

## Install paths

### Skills and tools for an existing Codex setup

```fish
curl -fsSL https://raw.githubusercontent.com/grimmely/pair-codex-setup/main/bootstrap.sh | bash -s -- --skills-only
```

Installs the global pairing skills, this handoff tool, and our
[`GrimalDev/codex-session-exporter`](https://github.com/GrimalDev/codex-session-exporter)
fork. Codex configuration and plugins stay untouched. Start a new Codex session,
then use `$handoff configure` to select your private storage repository.
See [setup prerequisites](https://github.com/grimmely/pair-codex-setup#before-installation)
for required commands and versions.

### Complete Codex setup

```fish
curl -fsSL https://raw.githubusercontent.com/grimmely/pair-codex-setup/main/bootstrap.sh | bash
```

The installer installs the exporter fork automatically, asks for the private
storage repository, installs the tool and `handoff` skill, then configures
the local storage checkout.

### Standalone tool

Install our `GrimalDev/codex-session-exporter` fork, version 0.2.0 or newer, first:

```fish
curl -fsSL https://raw.githubusercontent.com/GrimalDev/codex-session-exporter/main/scripts/install-from-github.sh | bash
```

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

After `pair-codex-setup`, choose `handoff` from Codex's slash-command list or
type `$handoff`. Ask it to send, receive, inspect status, or configure storage.
It asks for confirmation immediately before cloning, importing, committing, or
pushing.

Use `$handoff help` for a short command menu. It explains `send`, `receive`,
`status`, and `configure` without changing state.

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

To send a particular session, add `--session-id SESSION_ID`. Its starting
directory may be outside the repository, for example its parent folder.
`--source-repo` still selects the Git metadata and tracked patch to attach.
The session must exist in the selected Codex home.

Without `--session-id`, the sender selects the newest matching session from
the 50 most recent sessions, requiring its starting directory to be inside
the source repository. The `handoff` skill passes the current session ID when
available and confirms the session and repository together before sending.

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
    YYYY/
      MM/
        DD/
          <timestamp>-<session-id>/
            HANDOFF.md
            session.codex-session.tar.gz
            source.patch                # only when tracked changes exist
```

Every handoff becomes one commit on `main`. The generated share URL points to
that commit in your private storage repository.

The compressed bundle contains only data required to restore the Codex session.
Export Markdown or HTML separately when a readable artifact is needed.

## Safety model

- Share storage only with trusted pair writers; imported conversation content is
  collaborator-provided data.
- Requires `fish`, `git`, `gh`, `tar`, Node.js, and
  `codex-session-exporter` 0.2.0 or newer.
- Validates configured storage remote, every push URL, private visibility, and
  `main` before sending or receiving.
- Refuses paths outside the selected harness directory.
- Receives commit URLs only from configured `main` history and materializes
  the exact committed bundle, never a later working-tree replacement.
- Warns above 50 MiB and refuses handoffs at 100 MiB.
- Writes `ustar` archives with macOS metadata disabled. Sender and receiver
  use the same structural validation before upload and extraction, refusing
  symbolic links, unexpected entries, and unsafe paths. Import also refuses
  existing session IDs.
- Strips sender approval, sandbox, permission, and network policy from an
  imported session; receiver policy remains local.
- Never checks out sender commits or applies `source.patch` automatically.

Review a patch before applying it:

```fish
git apply --check /path/to/source.patch
```
