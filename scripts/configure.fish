#!/usr/bin/env fish

set script_dir (path dirname (status filename))
source "$script_dir/lib/storage.fish"

function usage
    printf '%s\n' 'Usage:'
    printf '%s\n' '  fish scripts/pair-handoff.fish configure --storage-repo <owner/repo>'
end

function fail
    printf 'error: %s\n' "$argv" >&2
    exit 1
end

function checkout_has_known_empty_initialization --argument-names storage_checkout
    set local_heads (git -C "$storage_checkout" for-each-ref --format='%(refname)' refs/heads)
    or return 1
    test (count $local_heads) -eq 1
    and test "$local_heads[1]" = refs/heads/main
    or return 1

    set main_commit (git -C "$storage_checkout" rev-parse --verify refs/heads/main 2>/dev/null)
    or return 1
    set head_commit (git -C "$storage_checkout" rev-parse --verify HEAD 2>/dev/null)
    or return 1
    test "$head_commit" = "$main_commit"
    or return 1

    git -C "$storage_checkout" rev-parse --verify "$main_commit^" >/dev/null 2>&1
    and return 1
    test (git -C "$storage_checkout" log -1 --format=%s "$main_commit") = 'chore: initialize handoff storage'
    or return 1

    set changed_paths (git -C "$storage_checkout" diff-tree --root --no-commit-id --name-only -r "$main_commit")
    not set -q changed_paths[1]
end

function storage_checkout_has_no_remote_refs --argument-names storage_checkout
    set remote_refs (git -C "$storage_checkout" ls-remote --refs origin 2>/dev/null)
    or return 1
    not set -q remote_refs[1]
end

function initialize_empty_storage_repo --argument-names storage_checkout
    set checkout_status (git -C "$storage_checkout" status --porcelain)
    or return 1
    if set -q checkout_status[1]
        return 1
    end

    set local_heads (git -C "$storage_checkout" for-each-ref --format='%(refname)' refs/heads)
    or return 1
    if set -q local_heads[1]
        checkout_has_known_empty_initialization "$storage_checkout"
        or return 1
    else
        if git -C "$storage_checkout" rev-parse --verify --quiet HEAD >/dev/null
            return 1
        end

        printf '%s\n' 'Initializing empty private handoff storage on main.'
        git -C "$storage_checkout" checkout --orphan main
        or return 1

        set git_user_name (git -C "$storage_checkout" config --get user.name 2>/dev/null)
        set git_user_email (git -C "$storage_checkout" config --get user.email 2>/dev/null)
        if set -q git_user_name[1]; and set -q git_user_email[1]
            git -C "$storage_checkout" commit --allow-empty -m 'chore: initialize handoff storage'
            or return 1
        else
            printf '%s\n' 'Git user identity is unavailable; using Pair Codex Handoffs for the empty commit.'
            git -C "$storage_checkout" \
                -c user.name='Pair Codex Handoffs' \
                -c user.email='noreply@github.com' \
                commit --allow-empty -m 'chore: initialize handoff storage'
            or return 1
        end
    end

    storage_checkout_has_no_remote_refs "$storage_checkout"
    or return 1
    git -C "$storage_checkout" push --set-upstream origin main
end

argparse 'h/help' 'storage-repo=' -- $argv
or begin
    usage
    exit 2
end

if set -q _flag_help
    usage
    exit 0
end

if not set -q _flag_storage_repo
    usage
    fail 'Missing --storage-repo.'
end

set storage_repo "$_flag_storage_repo"
pair_handoff_validate_storage_repo "$storage_repo"
or fail 'Storage repository must use the form owner/repo.'

for command_name in gh git
    type -q "$command_name"
    or fail "Missing required command: $command_name"
end

pair_handoff_verify_private_writable_main_or_unset "$storage_repo"
or fail "Storage repository must be private, writable through gh, and use main or no default branch: $storage_repo"

set storage_checkout (pair_handoff_storage_checkout "$storage_repo")
or fail 'Could not resolve the storage checkout path.'

set checkout_parent (path dirname "$storage_checkout")
command mkdir -p "$checkout_parent"
or fail "Could not create storage parent: $checkout_parent"
command chmod 700 "$checkout_parent"
or fail "Could not secure storage parent: $checkout_parent"

if test -e "$storage_checkout"
    pair_handoff_validate_storage_checkout_identity "$storage_repo" "$storage_checkout"
    or fail "Existing storage checkout does not match $storage_repo: $storage_checkout"
else
    gh repo clone "https://github.com/$storage_repo.git" "$storage_checkout"
    or fail "Could not clone storage repository: $storage_repo"
    pair_handoff_validate_storage_checkout_identity "$storage_repo" "$storage_checkout"
    or fail "Storage checkout did not validate after cloning: $storage_checkout"
end

set remote_refs (git -C "$storage_checkout" ls-remote --refs origin 2>/dev/null)
or fail "Could not inspect storage repository refs: $storage_repo"
if not set -q remote_refs[1]
    initialize_empty_storage_repo "$storage_checkout"
    or fail "Could not initialize empty storage repository: $storage_repo. It may have changed; rerun configure."
end

pair_handoff_verify_private_main "$storage_repo"
or fail "Storage repository must be private, writable through gh, and use main: $storage_repo"
pair_handoff_validate_storage_checkout "$storage_repo" "$storage_checkout"
or fail "Storage checkout did not validate after configuring main: $storage_checkout"

pair_handoff_write_storage_repo "$storage_repo"
or fail 'Could not save the storage repository configuration.'

printf '%s\n' "Storage repository: $storage_repo"
printf '%s\n' "Storage checkout: $storage_checkout"
