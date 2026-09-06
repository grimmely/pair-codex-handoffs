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

pair_handoff_verify_private_main "$storage_repo"
or fail "Storage repository must be private, writable through gh, and use main: $storage_repo"

set storage_checkout (pair_handoff_storage_checkout "$storage_repo")
or fail 'Could not resolve the storage checkout path.'

set checkout_parent (path dirname "$storage_checkout")
command mkdir -p "$checkout_parent"
or fail "Could not create storage parent: $checkout_parent"
command chmod 700 "$checkout_parent"
or fail "Could not secure storage parent: $checkout_parent"

if test -e "$storage_checkout"
    pair_handoff_validate_storage_checkout "$storage_repo" "$storage_checkout"
    or fail "Existing storage checkout does not match $storage_repo: $storage_checkout"
else
    gh repo clone "https://github.com/$storage_repo.git" "$storage_checkout"
    or fail "Could not clone storage repository: $storage_repo"
    pair_handoff_validate_storage_checkout "$storage_repo" "$storage_checkout"
    or fail "Storage checkout did not validate after cloning: $storage_checkout"
end

pair_handoff_write_storage_repo "$storage_repo"
or fail 'Could not save the storage repository configuration.'

printf '%s\n' "Storage repository: $storage_repo"
printf '%s\n' "Storage checkout: $storage_checkout"
