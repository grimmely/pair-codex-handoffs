# Cross-Harness Handoff Design

## Purpose

Keep the handoff tool public while storing session material only in a
user-selected private GitHub repository.

## Repository boundary

```text
grimmely/pair-codex-handoffs  public tool, skill, and harness adapters
grimmely/pair-codex-setup     complete Codex pairing installer
user-selected private repo    handoff bundles and share URLs
```

The public repository never receives a transcript, patch, or session bundle.

## Storage configuration

Installation asks once for an existing GitHub `owner/repo` value. The user
creates that repository, keeps it private, gives their partner access, and
makes it available through `gh` before installation.

The tool verifies private visibility and `main` as the default branch. It
stores the selected slug beneath `PAIR_CODEX_HOME` and clones the repository
there. Changing storage later creates or reuses a separate local checkout;
it never replaces an existing checkout.

## Command surface

One Fish dispatcher is the implementation boundary:

```text
pair-handoff.fish configure --storage-repo owner/repo
pair-handoff.fish status
pair-handoff.fish send --harness codex ...
pair-handoff.fish receive --harness codex ...
```

Each harness supplies only a native command/skill shim. The Codex skill is
named `handoff`; enabled skills appear in Codex's slash-command list and may
also be invoked as `$handoff`.

## Harnesses

The registry makes future adapters additive. The only supported adapter in
this release is `codex`. Its exporter and importer remain Codex-specific.

```text
handoffs/codex/YYYY/MM/DD/<timestamp>-<session-id>/
```

An unknown harness fails before writing data.

## Safety invariants

- Storage remote, every push URL, GitHub visibility, and branch must match
  configured private storage.
- Storage remains on `main`.
- A receive path must stay below the configured storage checkout and selected
  harness directory.
- Existing archive, size, path, collision, and patch-application safeguards
  remain unchanged.
