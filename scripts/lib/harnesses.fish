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

function pair_handoff_require_minimal_bundle_exporter
    set exporter_version (codex-session-exporter --version 2>/dev/null)

    if test (count $exporter_version) -ne 1
        printf '%s\n' \
            'error: codex-session-exporter 0.2.0 or newer is required for minimal handoff bundles.' >&2
        return 1
    end

    if not string match -rq '^[0-9]+\.[0-9]+\.[0-9]+$' -- "$exporter_version[1]"
        printf '%s\n' \
            'error: codex-session-exporter 0.2.0 or newer is required for minimal handoff bundles.' >&2
        return 1
    end

    set version_parts (string split . -- "$exporter_version[1]")
    if test "$version_parts[1]" -eq 0; and test "$version_parts[2]" -lt 2
        printf '%s\n' \
            'error: codex-session-exporter 0.2.0 or newer is required for minimal handoff bundles.' >&2
        return 1
    end
end
