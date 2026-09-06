#!/usr/bin/env fish

set script_dir (path dirname (status filename))

function usage
    printf '%s\n' 'Usage:'
    printf '%s\n' '  fish scripts/pair-handoff.fish configure --storage-repo <owner/repo>'
    printf '%s\n' '  fish scripts/pair-handoff.fish status'
    printf '%s\n' '  fish scripts/pair-handoff.fish send [send options]'
    printf '%s\n' '  fish scripts/pair-handoff.fish receive [receive options]'
end

if not set -q argv[1]
    usage
    exit 2
end

set action $argv[1]
set arguments $argv[2..-1]

switch "$action"
    case configure
        command fish "$script_dir/configure.fish" $arguments
    case status
        command fish "$script_dir/status.fish" $arguments
    case send
        command fish "$script_dir/handoff.fish" $arguments
    case receive
        command fish "$script_dir/receive.fish" $arguments
    case help --help -h
        usage
    case '*'
        usage
        printf 'error: Unknown handoff action: %s\n' "$action" >&2
        exit 2
end
