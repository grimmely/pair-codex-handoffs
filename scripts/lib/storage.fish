function pair_handoff_home
    set home "$HOME/.pair-codex"
    if set -q PAIR_CODEX_HOME
        set home "$PAIR_CODEX_HOME"
    else if set -q CODEX_HOME
        set home "$CODEX_HOME"
    end

    path normalize -- "$home"
end

function pair_handoff_storage_config_dir
    printf '%s\n' (pair_handoff_home)/handoff
end

function pair_handoff_storage_config_file
    printf '%s\n' (pair_handoff_storage_config_dir)/storage-repo
end

function pair_handoff_validate_storage_repo --argument-names storage_repo
    string match -rq \
        '^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$' \
        -- "$storage_repo"
end

function pair_handoff_storage_checkout --argument-names storage_repo
    pair_handoff_validate_storage_repo "$storage_repo"
    or return 1

    set repository_parts (string split / -- "$storage_repo")
    printf '%s\n' (pair_handoff_home)/handoff-storage/$repository_parts[1]/$repository_parts[2]
end

function pair_handoff_read_storage_repo
    set config_file (pair_handoff_storage_config_file)
    if not test -f "$config_file"; or test -L "$config_file"
        return 1
    end

    set storage_repo (string trim -- (command cat -- "$config_file"))
    if not pair_handoff_validate_storage_repo "$storage_repo"
        return 1
    end

    printf '%s\n' "$storage_repo"
end

function pair_handoff_write_storage_repo --argument-names storage_repo
    pair_handoff_validate_storage_repo "$storage_repo"
    or return 1

    set config_dir (pair_handoff_storage_config_dir)
    command mkdir -p "$config_dir"
    or return 1
    command chmod 700 "$config_dir"
    or return 1

    set temporary_file (mktemp "$config_dir/.storage-repo.XXXXXX")
    or return 1
    printf '%s\n' "$storage_repo" > "$temporary_file"
    or begin
        command rm -f "$temporary_file"
        return 1
    end
    command chmod 600 "$temporary_file"
    or begin
        command rm -f "$temporary_file"
        return 1
    end
    command mv -f "$temporary_file" (pair_handoff_storage_config_file)
end

function pair_handoff_github_slug_from_remote --argument-names remote_url
    if string match -rq '^git@github\.com:' -- "$remote_url"
        set slug (string replace -r '^git@github\.com:' '' -- "$remote_url")
    else if string match -rq '^ssh://git@github\.com/' -- "$remote_url"
        set slug (string replace -r '^ssh://git@github\.com/' '' -- "$remote_url")
    else if string match -rq '^https://([^/@]+@)?github\.com/' -- "$remote_url"
        set slug (string replace -r '^https://([^/@]+@)?github\.com/' '' -- "$remote_url")
    else
        return 1
    end
    set slug (string replace -r '\.git$' '' -- "$slug")

    if pair_handoff_validate_storage_repo "$slug"
        printf '%s\n' "$slug"
    end
end

function pair_handoff_repository_metadata --argument-names storage_repo
    gh api --hostname github.com "repos/$storage_repo" \
        --jq '[.private, (.default_branch // ""), (.permissions.push // false)] | @tsv' 2>/dev/null
end

function pair_handoff_verify_private_writable_main_or_unset --argument-names storage_repo
    set repository_metadata (pair_handoff_repository_metadata "$storage_repo")
    or return 1
    set metadata_fields (string split \t -- "$repository_metadata")

    test (count $metadata_fields) -eq 3
    and test "$metadata_fields[1]" = true
    and begin
        test -z "$metadata_fields[2]"
        or test "$metadata_fields[2]" = main
    end
    and test "$metadata_fields[3]" = true
end

function pair_handoff_verify_private_main --argument-names storage_repo
    set repository_metadata (pair_handoff_repository_metadata "$storage_repo")
    or return 1
    set metadata_fields (string split \t -- "$repository_metadata")

    test (count $metadata_fields) -eq 3
    and test "$metadata_fields[1]" = true
    and test "$metadata_fields[2]" = main
    and test "$metadata_fields[3]" = true
end

function pair_handoff_validate_storage_checkout_identity --argument-names storage_repo checkout
    pair_handoff_validate_storage_repo "$storage_repo"
    or return 1
    test -d "$checkout"
    and not test -L "$checkout"
    or return 1

    set checkout_root (git -C "$checkout" rev-parse --show-toplevel 2>/dev/null)
    or return 1
    set checkout_root (path resolve -- "$checkout_root")
    set resolved_checkout (path resolve -- "$checkout")
    test "$checkout_root" = "$resolved_checkout"
    or return 1

    set origin_url (git -C "$resolved_checkout" remote get-url origin 2>/dev/null)
    or return 1
    set origin_slug (pair_handoff_github_slug_from_remote "$origin_url")
    test "$origin_slug" = "$storage_repo"
    or return 1

    set push_urls (git -C "$resolved_checkout" remote get-url --push --all origin 2>/dev/null)
    test (count $push_urls) -gt 0
    or return 1
    for push_url in $push_urls
        set push_slug (pair_handoff_github_slug_from_remote "$push_url")
        test "$push_slug" = "$storage_repo"
        or return 1
    end
end

function pair_handoff_validate_storage_checkout --argument-names storage_repo checkout
    pair_handoff_validate_storage_checkout_identity "$storage_repo" "$checkout"
    or return 1

    set resolved_checkout (path resolve -- "$checkout")
    or return 1
    test (git -C "$resolved_checkout" branch --show-current) = main
    or return 1
    git -C "$resolved_checkout" ls-remote --exit-code --heads origin refs/heads/main >/dev/null 2>&1
end

function pair_handoff_path_is_within --argument-names candidate parent
    if test "$candidate" = "$parent"
        return 0
    end

    set prefix "$parent/"
    set prefix_length (string length -- "$prefix")
    if test (string length -- "$candidate") -lt "$prefix_length"
        return 1
    end

    test (string sub -s 1 -l "$prefix_length" -- "$candidate") = "$prefix"
end
