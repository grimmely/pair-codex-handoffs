#!/usr/bin/env fish

set script_dir (path dirname (status filename))
source "$script_dir/lib/harnesses.fish"
source "$script_dir/lib/storage.fish"

set -g warning_threshold_bytes 52428800
set -g maximum_handoff_bytes 104857600
set -g tar_overhead_reserve_bytes 65536

function usage
    printf '%s\n' 'Usage:'
    printf '%s\n' '  fish scripts/pair-handoff.fish send --source-repo <path> [--harness codex] [--codex-home <path>] [--session-id <id>] [--note <text>]'
end

function fail
    printf 'error: %s\n' "$argv" >&2
    exit 1
end

function require_command --argument-names command_name
    if not type -q "$command_name"
        fail "Missing required command: $command_name"
    end
end

function cleanup_staging --argument-names staging_dir
    if test -n "$staging_dir"; and test -d "$staging_dir"
        command rm -rf "$staging_dir"
    end
end

function cleanup_pending_handoff --argument-names handoff_root relative_dir output_dir staging_dir
    cleanup_staging "$staging_dir"

    if test -n "$handoff_root"; and test -n "$relative_dir"
        git -C "$handoff_root" rm -r --cached --ignore-unmatch -- "$relative_dir" >/dev/null 2>&1
    end

    if test -n "$output_dir"; and test -d "$output_dir"
        command rm -rf "$output_dir"
    end
end

function github_commit_url --argument-names remote_url commit_sha
    set repo_slug (pair_handoff_github_slug_from_remote "$remote_url")
    if set -q repo_slug[1]
        printf 'https://github.com/%s/commit/%s\n' "$repo_slug" "$commit_sha"
    end
end

function display_remote_url --argument-names remote_url
    set display_url (string replace -r '^[[:alpha:]][[:alnum:]+.-]*://' '' -- "$remote_url")
    set display_url (string replace -r '^[^/]*@' '' -- "$display_url")
    set display_url (string replace -r '[?#].*$' '' -- "$display_url")
    printf '%s\n' "$display_url"
end

function session_cwd --argument-names session_id codex_home
    set inspection_lines (codex-session-exporter inspect "$session_id" --codex-home "$codex_home")
    or return 1
    set inspection (string join \n -- $inspection_lines)
    set encoded_cwd (string match -r --groups-only '"cwd"[[:space:]]*:[[:space:]]*"([^"]*)"' -- "$inspection")

    if not set -q encoded_cwd[1]
        return 1
    end

    path resolve -- "$encoded_cwd[1]"
end

function path_is_within --argument-names candidate parent
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

function session_matches_source --argument-names session_id source_root codex_home
    set candidate_cwd (session_cwd "$session_id" "$codex_home")
    or return 1
    path_is_within "$candidate_cwd" "$source_root"
end

function handoff_destination_is_safe --argument-names handoff_root relative_dir
    set resolved_handoff_root (path resolve -- "$handoff_root")
    if not set -q resolved_handoff_root[1]
        return 1
    end

    set candidate "$resolved_handoff_root"
    for component in (string split / -- "$relative_dir")
        if test -z "$component"; or test "$component" = .; or test "$component" = ..
            return 1
        end

        set candidate "$candidate/$component"
        if test -L "$candidate"
            return 1
        end

        if test -e "$candidate"
            set resolved_candidate (path resolve -- "$candidate")
            if not set -q resolved_candidate[1]; or not pair_handoff_path_is_within "$resolved_candidate" "$resolved_handoff_root"
                return 1
            end
        end
    end
end

function handoff_size_is_safe --argument-names handoff_dir
    set total_bytes 0

    for artifact_path in \
        "$handoff_dir/HANDOFF.md" \
        "$handoff_dir/transcript.md" \
        "$handoff_dir/session.codex-session.tar.gz" \
        "$handoff_dir/source-status.txt" \
        "$handoff_dir/source.patch"
        if not test -f "$artifact_path"
            continue
        end

        set artifact_bytes (command wc -c < "$artifact_path")
        set artifact_bytes (string trim -- "$artifact_bytes")
        if not string match -rq '^[0-9]+$' -- "$artifact_bytes"
            printf 'error: Could not measure artifact: %s\n' "$artifact_path" >&2
            return 1
        end

        set total_bytes (math "$total_bytes + $artifact_bytes")
    end

    if test "$total_bytes" -ge "$maximum_handoff_bytes"
        printf 'error: Handoff totals 100 MiB or more; GitHub regular Git cannot safely store it.\n' >&2
        return 1
    end

    if test "$total_bytes" -gt "$warning_threshold_bytes"
        printf 'warning: Handoff totals more than 50 MiB; Git history will grow quickly.\n' >&2
    end
end

function bundle_size_is_safe --argument-names bundle_dir
    set total_bytes 0

    for relative_file in \
        manifest.json \
        transcript.md \
        transcript.html \
        raw/session.jsonl \
        raw/thread.json \
        raw/thread-dynamic-tools.json \
        raw/index-record.json
        set bundle_file "$bundle_dir/$relative_file"
        if not test -f "$bundle_file"
            printf 'error: Exported bundle is missing: %s\n' "$relative_file" >&2
            return 1
        end

        set file_bytes (command wc -c < "$bundle_file")
        set file_bytes (string trim -- "$file_bytes")
        if not string match -rq '^[0-9]+$' -- "$file_bytes"
            printf 'error: Could not measure exported bundle file: %s\n' "$relative_file" >&2
            return 1
        end

        set total_bytes (math "$total_bytes + $file_bytes")
    end

    # Seven files, two directories, padding, and tar end blocks fit in 64 KiB.
    set maximum_payload_bytes (math "$maximum_handoff_bytes - $tar_overhead_reserve_bytes")
    if test "$total_bytes" -gt "$maximum_payload_bytes"
        printf 'error: Uncompressed session bundle leaves too little room for tar metadata.\n' >&2
        return 1
    end
end

function archive_layout_is_safe --argument-names archive_path
    set expected_entries \
        session.codex-session/ \
        session.codex-session/manifest.json \
        session.codex-session/transcript.md \
        session.codex-session/transcript.html \
        session.codex-session/raw/ \
        session.codex-session/raw/session.jsonl \
        session.codex-session/raw/thread.json \
        session.codex-session/raw/thread-dynamic-tools.json \
        session.codex-session/raw/index-record.json
    set archive_entries (tar -tzf "$archive_path")
    or return 1

    if test (count $archive_entries) -ne (count $expected_entries)
        return 1
    end

    for expected_entry in $expected_entries
        if not contains -- "$expected_entry" $archive_entries
            return 1
        end
    end

    for archive_entry in $archive_entries
        if not contains -- "$archive_entry" $expected_entries
            return 1
        end
    end
end

argparse \
    'h/help' \
    'harness=' \
    'source-repo=' \
    'codex-home=' \
    'session-id=' \
    'note=' \
    -- $argv
or begin
    usage
    exit 2
end

if set -q _flag_help
    usage
    exit 0
end

if not set -q _flag_source_repo
    usage
    fail 'Missing --source-repo.'
end

set harness codex
if set -q _flag_harness
    set harness "$_flag_harness"
end
pair_handoff_require_supported_harness "$harness"
or exit 1

for command_name in codex-session-exporter git tar gh
    require_command "$command_name"
end

set requested_codex_home "$HOME/.codex"
if set -q CODEX_HOME
    set requested_codex_home "$CODEX_HOME"
end
if set -q _flag_codex_home
    set requested_codex_home "$_flag_codex_home"
end

set codex_home (path resolve -- "$requested_codex_home")
if not set -q codex_home[1]; or not test -d "$codex_home"
    fail "Codex home does not exist: $requested_codex_home"
end

if not test -d "$_flag_source_repo"
    fail "Source repository does not exist: $_flag_source_repo"
end

set storage_repo (pair_handoff_read_storage_repo)
if not set -q storage_repo[1]
    fail 'No storage repository is configured. Run /handoff configure first.'
end

set handoff_root (pair_handoff_storage_checkout "$storage_repo")
if not set -q handoff_root[1]
    fail 'Could not resolve the configured storage checkout.'
end
pair_handoff_validate_storage_checkout "$storage_repo" "$handoff_root"
or fail "Configured storage checkout does not match $storage_repo: $handoff_root"

set source_root (git -C "$_flag_source_repo" rev-parse --show-toplevel 2>/dev/null)
if not set -q source_root[1]
    fail "Not a Git repository: $_flag_source_repo"
end
set source_root (path resolve -- "$source_root")

set handoff_branch (git -C "$handoff_root" branch --show-current)
if not set -q handoff_branch[1]
    fail 'Handoff repository must be on a local branch.'
end
if test "$handoff_branch" != main
    fail 'Handoff storage must use the main branch.'
end

set handoff_status (git -C "$handoff_root" status --porcelain)
if set -q handoff_status[1]
    fail "Handoff repository has uncommitted changes: $handoff_root"
end

set remote_url (git -C "$handoff_root" remote get-url origin 2>/dev/null)
if not set -q remote_url[1]
    fail "Handoff repository has no origin remote: $handoff_root"
end

set remote_slug (pair_handoff_github_slug_from_remote "$remote_url")
if not set -q remote_slug[1]; or test "$remote_slug" != "$storage_repo"
    fail "Handoff origin must be configured storage repository: $storage_repo"
end

set push_urls (git -C "$handoff_root" remote get-url --push --all origin 2>/dev/null)
if not set -q push_urls[1]
    fail "Handoff origin has no push URL: $storage_repo"
end

for push_url in $push_urls
    set push_slug (pair_handoff_github_slug_from_remote "$push_url")
    if not set -q push_slug[1]; or test "$push_slug" != "$storage_repo"
        fail "Every handoff push URL must be configured storage repository: $storage_repo"
    end
end

pair_handoff_verify_private_main "$storage_repo"
or fail "Handoff storage must be private, writable through gh, and use main: $storage_repo"

set handoff_upstream (git -C "$handoff_root" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)
if not set -q handoff_upstream[1]; or test "$handoff_upstream" != origin/main
    fail 'Handoff storage main branch must track origin/main.'
end
git -C "$handoff_root" pull --ff-only origin main
or fail 'Could not fast-forward the handoff storage from origin/main.'
set fetched_handoff_commit (git -C "$handoff_root" rev-parse --verify FETCH_HEAD^{commit} 2>/dev/null)
set current_handoff_commit (git -C "$handoff_root" rev-parse --verify HEAD^{commit} 2>/dev/null)
if not set -q fetched_handoff_commit[1]; or not set -q current_handoff_commit[1]; or \
    test "$fetched_handoff_commit" != "$current_handoff_commit"
    fail 'Handoff storage main is not exactly the fetched origin/main commit.'
end

set session_id
if set -q _flag_session_id
    set session_id "$_flag_session_id"
else
    set session_lines (codex-session-exporter list --limit 50 --codex-home "$codex_home")
    or fail 'Could not list local Codex sessions.'

    for session_line in $session_lines
        set candidate_id (string split \t -- "$session_line")[1]
        if string match -rq '^[0-9A-Fa-f-]{36}$' -- "$candidate_id"
            if session_matches_source "$candidate_id" "$source_root" "$codex_home"
                set session_id "$candidate_id"
                break
            end
        end
    end
end

if not set -q session_id[1]
    fail "No recent Codex session belongs to source repository: $source_root. Pass --session-id explicitly."
end

if not string match -rq '^[0-9A-Fa-f-]{36}$' -- "$session_id"
    fail "Invalid session ID: $session_id"
end

if not session_matches_source "$session_id" "$source_root" "$codex_home"
    fail "Session is not rooted in source repository: $source_root"
end

set timestamp (date -u '+%Y-%m-%dT%H-%M-%SZ')
set handoff_date (string replace -r 'T.*$' '' -- "$timestamp")
set handoff_date (string replace -a '-' '/' -- "$handoff_date")
set handoff_id "$timestamp-$session_id"
set relative_dir "handoffs/$harness/$handoff_date/$handoff_id"
set output_dir "$handoff_root/$relative_dir"

handoff_destination_is_safe "$handoff_root" "$relative_dir"
or fail 'Configured handoff destination must not contain symbolic links or leave storage.'

if test -e "$output_dir"; or test -L "$output_dir"
    fail "Handoff already exists: $output_dir"
end

set source_commit (git -C "$source_root" rev-parse HEAD 2>/dev/null)
if not set -q source_commit[1]
    set source_commit '(unborn)'
end

set source_branch (git -C "$source_root" branch --show-current)
if not set -q source_branch[1]
    set source_branch '(detached)'
end

set source_remote_raw (git -C "$source_root" remote get-url origin 2>/dev/null)
if set -q source_remote_raw[1]
    set source_remote (display_remote_url "$source_remote_raw")
else
    set source_remote '(no origin remote)'
end

set sender_note 'No sender note supplied.'
if set -q _flag_note
    set sender_note "$_flag_note"
end

set staging_dir (mktemp -d)
if not set -q staging_dir[1]
    fail 'Could not create a temporary export directory.'
end

set staged_handoff_dir "$staging_dir/$handoff_id"
command mkdir -p "$staged_handoff_dir"
or begin
    cleanup_staging "$staging_dir"
    fail 'Could not create a temporary handoff directory.'
end

set source_status "$staged_handoff_dir/source-status.txt"
git -C "$source_root" status --short > "$source_status"
or begin
    cleanup_staging "$staging_dir"
    fail 'Could not capture source repository status.'
end

set source_patch "$staged_handoff_dir/source.patch"
if test "$source_commit" = '(unborn)'
    set empty_tree (git -C "$source_root" hash-object -t tree /dev/null)
    or begin
        cleanup_staging "$staging_dir"
        fail 'Could not create an empty Git tree for the source patch.'
    end

    git -C "$source_root" diff --binary --cached "$empty_tree" > "$source_patch"
    or begin
        cleanup_staging "$staging_dir"
        fail 'Could not capture staged source changes.'
    end

    git -C "$source_root" diff --binary >> "$source_patch"
    or begin
        cleanup_staging "$staging_dir"
        fail 'Could not capture unstaged source changes.'
    end
else
    git -C "$source_root" diff --binary HEAD > "$source_patch"
    or begin
        cleanup_staging "$staging_dir"
        fail 'Could not capture tracked source changes.'
    end
end

set patch_state 'none'
if test -s "$source_patch"
    set patch_state 'included'
else
    command rm -f "$source_patch"
end

set receiver_commit_step
if test "$source_commit" = '(unborn)'
    set receiver_commit_step '1. Source repository had no commit; initialize or inspect it manually before using `source.patch`.'
else
    set receiver_commit_step "1. Check out source commit \`$source_commit\` in the source repository."
end

begin
    printf '# Async pair handoff\n\n'
    printf '%s\n' "- Created (UTC): \`$timestamp\`"
    printf '%s\n' "- Harness: \`$harness\`"
    printf '%s\n' "- Codex session: \`$session_id\`"
    printf '%s\n' "- Source repository: \`$source_remote\`"
    printf '%s\n' "- Source commit: \`$source_commit\`"
    printf '%s\n' "- Source branch: \`$source_branch\`"
    printf '%s\n' "- Tracked source patch: \`$patch_state\`"
    printf '\n## Sender note\n\n%s\n' "$sender_note"
    printf '%s\n' '## Receiver'
    printf '%s\n' ''
    printf '%s\n' "$receiver_commit_step"
    printf '%s\n' '2. Read `transcript.md` for working context.'
    printf '%s\n' '3. Review `source.patch` before applying it, if present.'
    printf '%s\n' '4. Run `receive.fish` to import the Codex bundle.'
    printf '%s\n' ''
    printf '%s\n' 'Untracked source files are listed in `source-status.txt`; they are not copied.'
end > "$staged_handoff_dir/HANDOFF.md"
or begin
    cleanup_staging "$staging_dir"
    fail 'Could not write handoff instructions.'
end

set transcript_path "$staged_handoff_dir/transcript.md"
set bundle_dir "$staging_dir/session.codex-session"
set bundle_archive "$staged_handoff_dir/session.codex-session.tar.gz"

codex-session-exporter export md "$session_id" --output "$transcript_path" --codex-home "$codex_home"
or begin
    cleanup_staging "$staging_dir"
    fail 'Could not export the readable transcript.'
end

codex-session-exporter export bundle "$session_id" --output "$bundle_dir" --codex-home "$codex_home"
or begin
    cleanup_staging "$staging_dir"
    fail 'Could not export the importable bundle.'
end

bundle_size_is_safe "$bundle_dir"
or begin
    cleanup_staging "$staging_dir"
    fail 'Importable session bundle is too large to receive safely.'
end

tar -C "$staging_dir" -czf "$bundle_archive" session.codex-session
or begin
    cleanup_staging "$staging_dir"
    fail 'Could not compress the importable bundle.'
end

archive_layout_is_safe "$bundle_archive"
or begin
    cleanup_staging "$staging_dir"
    fail 'Compressed bundle does not match the supported session layout.'
end

command rm -rf "$bundle_dir"

handoff_size_is_safe "$staged_handoff_dir"
or begin
    cleanup_staging "$staging_dir"
    fail 'Handoff is too large to store safely in regular Git.'
end

set output_parent (path dirname "$output_dir")
command mkdir -p "$output_parent"
or begin
    cleanup_staging "$staging_dir"
    fail 'Could not create the handoff destination directory.'
end

command mv "$staged_handoff_dir" "$output_dir"
or begin
    cleanup_pending_handoff "$handoff_root" "$relative_dir" "$output_dir" "$staging_dir"
    fail 'Could not publish the completed handoff into the repository.'
end
cleanup_staging "$staging_dir"
set staging_dir ''

git -C "$handoff_root" add -- "$relative_dir"
or begin
    cleanup_pending_handoff "$handoff_root" "$relative_dir" "$output_dir" "$staging_dir"
    fail 'Could not stage handoff files.'
end

git -C "$handoff_root" commit -m "handoff: $handoff_id"
or begin
    cleanup_pending_handoff "$handoff_root" "$relative_dir" "$output_dir" "$staging_dir"
    fail 'Could not commit handoff files.'
end

if not git -C "$handoff_root" push origin main
    git -C "$handoff_root" pull --rebase origin main
    or fail 'Handoff was committed locally, but rebase hit a conflict. Run: git status; resolve it, then git rebase --continue (or git rebase --abort), then git push origin main.'
    git -C "$handoff_root" push origin main
    or fail 'Handoff was rebased onto origin/main, but push still failed. Recover with: git push origin main'
end

set commit_sha (git -C "$handoff_root" rev-parse HEAD)
set share_url (github_commit_url "$remote_url" "$commit_sha")

printf '%s\n' "Handoff: $output_dir"
printf '%s\n' "Share URL: $share_url"
