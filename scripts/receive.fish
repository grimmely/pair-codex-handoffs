#!/usr/bin/env fish

set script_dir (path dirname (status filename))
source "$script_dir/lib/harnesses.fish"
source "$script_dir/lib/storage.fish"

function usage
    printf '%s\n' 'Usage:'
    printf '%s\n' '  fish scripts/pair-handoff.fish receive --handoff <shared-url|handoffs/path|latest> --target-cwd <source-project-path> [--harness codex] [--codex-home <path>]'
    printf '%s\n' '  fish scripts/pair-handoff.fish receive --handoff-dir <path> --target-cwd <source-project-path> [--harness codex] [--codex-home <path>]'
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

function cleanup_extraction --argument-names extraction_dir
    if test -n "$extraction_dir"; and test -d "$extraction_dir"
        command rm -rf "$extraction_dir"
    end
end

function handoff_exists_in_commit --argument-names storage_root commit_sha handoff_relative_dir
    set handoff_type (git -C "$storage_root" cat-file -t \
        "$commit_sha:$handoff_relative_dir/HANDOFF.md" 2>/dev/null)
    test "$handoff_type" = blob
end

function handoff_relative_dir_pattern --argument-names harness
    printf '%s\n' "handoffs/$harness/[0-9]{4}/[0-9]{2}/[0-9]{2}/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
end

function latest_handoff_relative_dir --argument-names storage_root storage_commit harness
    set handoff_relative_dir (handoff_relative_dir_pattern "$harness")
    set handoff_relative_pattern "^($handoff_relative_dir)/HANDOFF\\.md\$"
    set handoff_paths (git -C "$storage_root" log --format= --name-only "$storage_commit" -- \
        "handoffs/$harness" | string match -r --groups-only "$handoff_relative_pattern")

    for handoff_path in $handoff_paths
        if handoff_exists_in_commit "$storage_root" "$storage_commit" "$handoff_path"
            printf '%s\n' "$handoff_path"
            return 0
        end
    end
    return 1
end

function resolve_handoff_source --argument-names handoff_reference storage_root storage_repo harness
    set handoff_relative_dir_pattern (handoff_relative_dir_pattern "$harness")
    set handoff_relative_pattern "^$handoff_relative_dir_pattern\$"
    set storage_commit (git -C "$storage_root" rev-parse --verify HEAD^{commit} 2>/dev/null)
    if not set -q storage_commit[1]
        return 1
    end

    if test "$handoff_reference" = latest
        set handoff_relative_dir (latest_handoff_relative_dir "$storage_root" "$storage_commit" "$harness")
        if not set -q handoff_relative_dir[1]
            return 1
        end
        printf '%s\n' git "$storage_commit" "$handoff_relative_dir"
        return 0
    end

    set url_match (string match -r --groups-only \
        '^https://github\\.com/([^/]+/[^/]+)/commit/([0-9A-Fa-f]{7,64})/?(?:[?#].*)?$' \
        -- "$handoff_reference")
    if set -q url_match[1]
        if test (count $url_match) -ne 2; or test "$url_match[1]" != "$storage_repo"
            return 1
        end

        set handoff_commit (git -C "$storage_root" rev-parse --verify "$url_match[2]^{commit}" 2>/dev/null)
        if not set -q handoff_commit[1]
            return 1
        end
        git -C "$storage_root" merge-base --is-ancestor "$handoff_commit" "$storage_commit"
        or return 1

        set handoff_paths (git -C "$storage_root" diff-tree --root --no-commit-id --name-only -r \
            "$handoff_commit" | string match -r --groups-only \
            "^($handoff_relative_dir_pattern)/HANDOFF\\.md\$")
        if test (count $handoff_paths) -ne 1
            return 1
        end
        if not handoff_exists_in_commit "$storage_root" "$handoff_commit" "$handoff_paths[1]"
            return 1
        end
        printf '%s\n' git "$handoff_commit" "$handoff_paths[1]"
        return 0
    end

    if string match -rq '^handoffs/' -- "$handoff_reference"
        if not string match -rq "$handoff_relative_pattern" -- "$handoff_reference"
            return 1
        end
        if not handoff_exists_in_commit "$storage_root" "$storage_commit" "$handoff_reference"
            return 1
        end
        printf '%s\n' git "$storage_commit" "$handoff_reference"
        return 0
    end

    set local_handoff_dir (path resolve -- "$handoff_reference")
    if not set -q local_handoff_dir[1]
        return 1
    end
    printf '%s\n' local "$local_handoff_dir"
end

function validate_archive --argument-names archive_path
    node -e '
const fs = require("node:fs");
const zlib = require("node:zlib");

const archivePath = process.argv[1];
const maximumBytes = 100 * 1024 * 1024;
const expectedEntries = new Map([
  ["session.codex-session/", "directory"],
  ["session.codex-session/manifest.json", "file"],
  ["session.codex-session/raw/", "directory"],
  ["session.codex-session/raw/session.jsonl", "file"],
  ["session.codex-session/raw/thread.json", "file"],
  ["session.codex-session/raw/thread-dynamic-tools.json", "file"],
  ["session.codex-session/raw/index-record.json", "file"],
]);

function isZeroBlock(block) {
  return block.every((byte) => byte === 0);
}

function readField(block, offset, length) {
  const field = block.subarray(offset, offset + length);
  const zero = field.indexOf(0);
  return field.subarray(0, zero === -1 ? field.length : zero).toString("utf8");
}

function readOctal(block, offset, length) {
  const value = readField(block, offset, length).trim();
  if (!/^[0-7]*$/.test(value)) {
    throw new Error("Archive contains a non-octal size field.");
  }

  return value ? Number.parseInt(value, 8) : 0;
}

let buffer = Buffer.alloc(0);
let complete = false;
let remaining = 0;
let padding = 0;
let state = "header";
let totalPayloadBytes = 0;
let totalUnpackedBytes = 0;
let zeroBlocks = 0;
const seenEntries = new Set();

function consume(chunk) {
  totalUnpackedBytes += chunk.length;
  if (totalUnpackedBytes > maximumBytes) {
    throw new Error("Archive expands beyond the 100 MiB safety limit.");
  }

  if (complete) {
    if (!isZeroBlock(chunk)) {
      throw new Error("Archive contains data after its end marker.");
    }
    return;
  }

  buffer = Buffer.concat([buffer, chunk]);

  while (true) {
    if (state === "header") {
      if (buffer.length < 512) {
        return;
      }

      const header = buffer.subarray(0, 512);
      buffer = buffer.subarray(512);

      if (isZeroBlock(header)) {
        zeroBlocks += 1;
        if (zeroBlocks === 2) {
          complete = true;
          if (!isZeroBlock(buffer)) {
            throw new Error("Archive contains data after its end marker.");
          }
          buffer = Buffer.alloc(0);
          return;
        }
        continue;
      }

      if (zeroBlocks > 0) {
        throw new Error("Archive has an incomplete end marker.");
      }

      const name = readField(header, 0, 100);
      const prefix = readField(header, 345, 155);
      const entryName = prefix ? `${prefix}/${name}` : name;
      const entryType = String.fromCharCode(header[156] || 48);
      const entrySize = readOctal(header, 124, 12);
      const expectedType = expectedEntries.get(entryName);

      if (!expectedType) {
        throw new Error(`Unexpected archive entry: ${entryName || "(empty)"}`);
      }
      if (seenEntries.has(entryName)) {
        throw new Error(`Duplicate archive entry: ${entryName}`);
      }
      if (expectedType === "directory" && (entryType !== "5" || entrySize !== 0)) {
        throw new Error(`Invalid directory entry: ${entryName}`);
      }
      if (expectedType === "file" && entryType !== "0") {
        throw new Error(`Archive entry is not a regular file: ${entryName}`);
      }

      seenEntries.add(entryName);
      totalPayloadBytes += entrySize;
      if (totalPayloadBytes > maximumBytes) {
        throw new Error("Archive payload exceeds the 100 MiB safety limit.");
      }

      remaining = entrySize;
      padding = (512 - (entrySize % 512)) % 512;
      state = "content";
      continue;
    }

    if (remaining > 0) {
      if (buffer.length === 0) {
        return;
      }

      const count = Math.min(remaining, buffer.length);
      buffer = buffer.subarray(count);
      remaining -= count;
      continue;
    }

    if (padding > 0) {
      if (buffer.length === 0) {
        return;
      }

      const count = Math.min(padding, buffer.length);
      buffer = buffer.subarray(count);
      padding -= count;
      continue;
    }

    state = "header";
  }
}

async function main() {
  const archiveStat = fs.statSync(archivePath);
  if (!archiveStat.isFile()) {
    throw new Error("Archive is not a regular file.");
  }
  if (archiveStat.size >= maximumBytes) {
    throw new Error("Compressed archive is 100 MiB or larger.");
  }

  const gunzip = fs.createReadStream(archivePath).pipe(zlib.createGunzip());
  for await (const chunk of gunzip) {
    consume(chunk);
  }

  if (!complete || state !== "header") {
    throw new Error("Archive ended before a complete tar payload was read.");
  }
  if (seenEntries.size !== expectedEntries.size) {
    throw new Error("Archive is missing expected session bundle entries.");
  }
}

main().catch((error) => {
  console.error(`error: ${error.message}`);
  process.exitCode = 1;
});
' "$archive_path"
end

function sanitize_manifest --argument-names bundle_dir
    node -e '
const fs = require("node:fs");
const path = require("node:path");

try {
const bundleDir = process.argv[1];
const manifestPath = path.join(bundleDir, "manifest.json");
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
const sessionId = String(manifest.sessionId || "");
const rolloutPath = String(manifest.paths?.rolloutRelativePath || "");
const sessionIdPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const rolloutPattern = /^(?:sessions|archived_sessions)\/\d{4}\/\d{2}\/\d{2}\/rollout-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$/;
const rolloutMatch = rolloutPath.match(rolloutPattern);

if (manifest.formatVersion !== 2) {
  throw new Error("Unsupported bundle format version.");
}
if (!sessionIdPattern.test(sessionId)) {
  throw new Error("Bundle manifest has an invalid session ID.");
}
if (!rolloutMatch || rolloutMatch[1] !== sessionId) {
  throw new Error("Bundle manifest has an unsafe rollout path.");
}

const safeManifest = {
  formatVersion: 2,
  sessionId,
  files: {
    dynamicToolsJson: "raw/thread-dynamic-tools.json",
    indexRecordJson: "raw/index-record.json",
    sessionJsonl: "raw/session.jsonl",
    threadJson: "raw/thread.json",
  },
  paths: { rolloutRelativePath: rolloutPath },
  source: {},
  title: "",
  exportedAt: "",
};

fs.writeFileSync(manifestPath, `${JSON.stringify(safeManifest, null, 2)}\n`, {
  encoding: "utf8",
  mode: 0o600,
});
console.log(sessionId);
} catch (error) {
  console.error(`error: ${error.message}`);
  process.exitCode = 1;
}
' "$bundle_dir"
end

function sanitize_sender_execution_context --argument-names bundle_dir target_cwd
    node -e '
const fs = require("node:fs");
const path = require("node:path");

function readObject(filePath) {
  const value = JSON.parse(fs.readFileSync(filePath, "utf8"));
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${path.basename(filePath)} must contain a JSON object.`);
  }
  return value;
}

function writeAtomically(filePath, value) {
  const temporaryPath = `${filePath}.${process.pid}.tmp`;
  fs.writeFileSync(temporaryPath, value, { encoding: "utf8", mode: 0o600, flag: "wx" });
  fs.renameSync(temporaryPath, filePath);
}

try {
  const bundleDir = process.argv[1];
  const targetCwd = process.argv[2];
  const rawDirectory = path.join(bundleDir, "raw");
  const threadPath = path.join(rawDirectory, "thread.json");
  const sessionPath = path.join(rawDirectory, "session.jsonl");
  const thread = readObject(threadPath);

  // Receiver policy belongs to the receiving Codex installation, not the sender.
  delete thread.approval_mode;
  delete thread.approval_policy;
  delete thread.sandbox_policy;
  writeAtomically(threadPath, `${JSON.stringify(thread, null, 2)}\n`);

  const policyKeys = [
    "active_permission_profile",
    "approval_mode",
    "approval_policy",
    "approvals_reviewer",
    "file_system_sandbox_policy",
    "network",
    "permission_profile",
    "sandbox_policy",
  ];
  const source = fs.readFileSync(sessionPath, "utf8");
  const sanitizedLines = source.split(/\r?\n/).map((line) => {
    if (!line.trim()) {
      return line;
    }

    try {
      const record = JSON.parse(line);
      if (record?.type !== "turn_context" || !record.payload ||
          typeof record.payload !== "object" || Array.isArray(record.payload)) {
        return line;
      }

      for (const key of policyKeys) {
        delete record.payload[key];
      }
      record.payload.cwd = targetCwd;
      record.payload.workspace_roots = [targetCwd];
      return JSON.stringify(record);
    } catch {
      return line;
    }
  });

  writeAtomically(sessionPath, `${sanitizedLines.join("\n").replace(/\n+$/, "")}\n`);
} catch (error) {
  console.error(`error: ${error.message}`);
  process.exitCode = 1;
}
' "$bundle_dir" "$target_cwd"
end

argparse 'h/help' 'harness=' 'handoff=' 'handoff-dir=' 'target-cwd=' 'codex-home=' -- $argv
or begin
    usage
    exit 2
end

if set -q _flag_help
    usage
    exit 0
end

if not set -q _flag_handoff; and not set -q _flag_handoff_dir
    usage
    fail 'Missing --handoff or --handoff-dir.'
end

if set -q _flag_handoff; and set -q _flag_handoff_dir
    usage
    fail 'Use either --handoff or --handoff-dir, not both.'
end

if not set -q _flag_target_cwd
    usage
    fail 'Missing --target-cwd.'
end

set harness codex
if set -q _flag_harness
    set harness "$_flag_harness"
end
pair_handoff_require_supported_harness "$harness"
or exit 1

for command_name in codex-session-exporter tar node cp mktemp git gh
    require_command "$command_name"
end
pair_handoff_require_minimal_bundle_exporter
or exit 1

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

if not test -d "$_flag_target_cwd"
    fail "Target working directory does not exist: $_flag_target_cwd"
end

set storage_repo (pair_handoff_read_storage_repo)
if not set -q storage_repo[1]
    fail 'No storage repository is configured. Run /handoff configure first.'
end

set storage_root (pair_handoff_storage_checkout "$storage_repo")
if not set -q storage_root[1]
    fail 'Could not resolve the configured storage checkout.'
end
pair_handoff_validate_storage_checkout "$storage_repo" "$storage_root"
or fail "Configured storage checkout does not match $storage_repo: $storage_root"

pair_handoff_verify_private_main "$storage_repo"
or fail "Handoff storage must be private, writable through gh, and use main: $storage_repo"

set storage_status (git -C "$storage_root" status --porcelain)
if set -q storage_status[1]
    fail "Handoff storage has uncommitted changes: $storage_root"
end
git -C "$storage_root" pull --ff-only origin main
or fail 'Could not fast-forward handoff storage from origin/main.'
set fetched_storage_commit (git -C "$storage_root" rev-parse --verify FETCH_HEAD^{commit} 2>/dev/null)
set current_storage_commit (git -C "$storage_root" rev-parse --verify HEAD^{commit} 2>/dev/null)
if not set -q fetched_storage_commit[1]; or not set -q current_storage_commit[1]; or \
    test "$fetched_storage_commit" != "$current_storage_commit"
    fail 'Handoff storage main is not exactly the fetched origin/main commit.'
end

set handoff_reference "$_flag_handoff_dir"
if set -q _flag_handoff
    set handoff_reference "$_flag_handoff"
end
set handoff_source (resolve_handoff_source "$handoff_reference" "$storage_root" "$storage_repo" "$harness")
if not set -q handoff_source[1]
    fail "Could not resolve a configured $harness handoff from: $handoff_reference"
end

set target_cwd (path resolve -- "$_flag_target_cwd")
if not set -q target_cwd[1]
    fail "Could not resolve target working directory: $_flag_target_cwd"
end

set resolved_storage_root (path resolve -- "$storage_root")
if not set -q resolved_storage_root[1]
    fail "Could not resolve configured $harness storage: $storage_root/handoffs/$harness"
end
set storage_handoffs_root "$resolved_storage_root/handoffs"
if test -L "$storage_handoffs_root"; or test -L "$storage_handoffs_root/$harness"
    fail "Configured $harness storage must not use symbolic links."
end
set harness_root (path resolve -- "$storage_handoffs_root/$harness")
if not set -q harness_root[1]; or not pair_handoff_path_is_within "$harness_root" "$resolved_storage_root"
    fail "Could not resolve configured $harness storage: $storage_root/handoffs/$harness"
end

set handoff_source_type "$handoff_source[1]"
set handoff_dir
set handoff_commit
set handoff_relative_dir
if test "$handoff_source_type" = git
    if test (count $handoff_source) -ne 3
        fail 'Git handoff source is malformed.'
    end
    set handoff_commit "$handoff_source[2]"
    set handoff_relative_dir "$handoff_source[3]"
    set handoff_dir "$storage_root/$handoff_relative_dir"
else if test "$handoff_source_type" = local
    if test (count $handoff_source) -ne 2
        fail 'Local handoff source is malformed.'
    end
    set handoff_dir (path resolve -- "$handoff_source[2]")
    if not set -q handoff_dir[1]; or not test -d "$handoff_dir"
        fail "Handoff directory does not exist: $handoff_source[2]"
    end
    if not pair_handoff_path_is_within "$handoff_dir" "$harness_root"
        fail "Handoff directory must be within configured $harness storage: $storage_root/handoffs/$harness"
    end
    set expected_handoff_relative_dir (handoff_relative_dir_pattern "$harness")
    set escaped_storage_root (string escape --style=regex -- "$resolved_storage_root")
    set local_handoff_relative_dir (string replace -r "^$escaped_storage_root/" '' -- "$handoff_dir")
    if not set -q local_handoff_relative_dir[1]; or \
        not string match -rq "^$expected_handoff_relative_dir\$" -- "$local_handoff_relative_dir"
        fail "Handoff directory must use the configured $harness date layout."
    end
else
    fail 'Handoff source type is unsupported.'
end

set extraction_dir (mktemp -d)
if not set -q extraction_dir[1]
    fail 'Could not create a temporary extraction directory.'
end

set local_archive "$extraction_dir/session.codex-session.tar.gz"
if test "$handoff_source_type" = git
    set archive_object "$handoff_commit:$handoff_relative_dir/session.codex-session.tar.gz"
    set archive_type (git -C "$storage_root" cat-file -t "$archive_object" 2>/dev/null)
    if test "$archive_type" != blob
        cleanup_extraction "$extraction_dir"
        fail 'Committed handoff bundle is not a regular Git blob.'
    end
    git -C "$storage_root" cat-file blob "$archive_object" > "$local_archive"
    or begin
        cleanup_extraction "$extraction_dir"
        fail 'Could not materialize the committed handoff bundle.'
    end
else
    set bundle_archive "$handoff_dir/session.codex-session.tar.gz"
    if not test -f "$bundle_archive"
        cleanup_extraction "$extraction_dir"
        fail "Compressed bundle does not exist: $bundle_archive"
    end
    if test -L "$bundle_archive"
        cleanup_extraction "$extraction_dir"
        fail 'Compressed bundle must not be a symbolic link.'
    end
    command cp "$bundle_archive" "$local_archive"
    or begin
        cleanup_extraction "$extraction_dir"
        fail 'Could not copy the compressed bundle into secure temporary storage.'
    end
end

validate_archive "$local_archive"
or begin
    cleanup_extraction "$extraction_dir"
    fail 'Compressed bundle failed structural safety checks.'
end

tar -xzf "$local_archive" -C "$extraction_dir"
or begin
    cleanup_extraction "$extraction_dir"
    fail 'Could not extract the importable bundle.'
end

set bundle_dir "$extraction_dir/session.codex-session"
for required_file in \
    manifest.json \
    raw/session.jsonl \
    raw/thread.json \
    raw/thread-dynamic-tools.json \
    raw/index-record.json
    if not test -f "$bundle_dir/$required_file"
        cleanup_extraction "$extraction_dir"
        fail "Archive is missing required bundle file: $required_file"
    end
end

set imported_session_id (sanitize_manifest "$bundle_dir")
if not set -q imported_session_id[1]
    cleanup_extraction "$extraction_dir"
    fail 'Bundle manifest failed path-safety validation.'
end

sanitize_sender_execution_context "$bundle_dir" "$target_cwd"
or begin
    cleanup_extraction "$extraction_dir"
    fail 'Bundle execution context could not be sanitized for this receiver.'
end

if codex-session-exporter inspect "$imported_session_id" --codex-home "$codex_home" >/dev/null 2>&1
    cleanup_extraction "$extraction_dir"
    fail "A local Codex session already uses this ID: $imported_session_id"
end

codex-session-exporter import bundle "$bundle_dir" --target-cwd "$target_cwd" --codex-home "$codex_home"
set import_status $status

cleanup_extraction "$extraction_dir"

if test "$import_status" -ne 0
    exit "$import_status"
end

if test "$handoff_source_type" = git
    set handoff_url "https://github.com/$storage_repo/tree/$handoff_commit/$handoff_relative_dir"
    printf '%s\n' "Handoff: $handoff_url"
    if git -C "$storage_root" cat-file -e "$handoff_commit:$handoff_relative_dir/source.patch" 2>/dev/null
        printf '%s\n' "Tracked source patch: $handoff_url/source.patch"
        printf '%s\n' 'Review it before applying with git apply --check.'
    end
else
    printf '%s\n' "Handoff: $handoff_dir"
    if test -f "$handoff_dir/source.patch"
        printf '%s\n' "Tracked source patch: $handoff_dir/source.patch"
        printf '%s\n' 'Review it before applying with git apply --check.'
    end
end
