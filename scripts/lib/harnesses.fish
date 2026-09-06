function pair_handoff_supported_harnesses
    printf '%s\n' codex
end

function pair_handoff_require_supported_harness --argument-names harness
    if contains -- "$harness" (pair_handoff_supported_harnesses)
        return 0
    end

    printf 'error: Unsupported harness: %s. Supported harnesses: %s\n' \
        "$harness" \
        (string join ', ' -- (pair_handoff_supported_harnesses)) >&2
    return 1
end
