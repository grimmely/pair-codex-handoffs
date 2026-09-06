#!/usr/bin/env fish

set script_dir (path dirname (status filename))
source "$script_dir/lib/harnesses.fish"
source "$script_dir/lib/storage.fish"

printf '%s\n' "Supported harnesses: "(string join ', ' -- (pair_handoff_supported_harnesses))

set storage_repo (pair_handoff_read_storage_repo)
if not set -q storage_repo[1]
    printf '%s\n' 'Storage repository: not configured'
    printf '%s\n' 'Configure: /handoff configure'
    exit 0
end

set storage_checkout (pair_handoff_storage_checkout "$storage_repo")
printf '%s\n' "Storage repository: $storage_repo"
printf '%s\n' "Storage checkout: $storage_checkout"

if pair_handoff_validate_storage_checkout "$storage_repo" "$storage_checkout"; and \
    pair_handoff_verify_private_main "$storage_repo"
    printf '%s\n' 'Storage checkout: ready'
else
    printf '%s\n' 'Storage checkout: needs attention'
    exit 1
end
