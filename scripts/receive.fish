#!/usr/bin/env fish

function usage
    printf '%s\n' 'Usage:'
    printf '%s\n' '  fish scripts/receive.fish --handoff-dir <path> --target-cwd <source-project-path>'
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

function validate_archive --argument-names archive_path
    node -e '
const fs = require("node:fs");
const zlib = require("node:zlib");

const archivePath = process.argv[1];
const maximumBytes = 100 * 1024 * 1024;
const expectedEntries = new Map([
  ["session.codex-session/", "directory"],
  ["session.codex-session/manifest.json", "file"],
  ["session.codex-session/transcript.md", "file"],
  ["session.codex-session/transcript.html", "file"],
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
const sessionIdPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const rolloutPattern = /^(?:sessions|archived_sessions)\/\d{4}\/\d{2}\/\d{2}\/rollout-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$/i;
const rolloutMatch = rolloutPath.match(rolloutPattern);

if (manifest.formatVersion !== 1) {
  throw new Error("Unsupported bundle format version.");
}
if (!sessionIdPattern.test(sessionId)) {
  throw new Error("Bundle manifest has an invalid session ID.");
}
if (!rolloutMatch || rolloutMatch[1].toLowerCase() !== sessionId.toLowerCase()) {
  throw new Error("Bundle manifest has an unsafe rollout path.");
}

const safeManifest = {
  formatVersion: 1,
  sessionId,
  files: {
    dynamicToolsJson: "raw/thread-dynamic-tools.json",
    htmlTranscript: "transcript.html",
    indexRecordJson: "raw/index-record.json",
    markdownTranscript: "transcript.md",
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

argparse 'h/help' 'handoff-dir=' 'target-cwd=' -- $argv
or begin
    usage
    exit 2
end

if set -q _flag_help
    usage
    exit 0
end

if not set -q _flag_handoff_dir
    usage
    fail 'Missing --handoff-dir.'
end

if not set -q _flag_target_cwd
    usage
    fail 'Missing --target-cwd.'
end

for command_name in codex-session-exporter tar node cp mktemp
    require_command "$command_name"
end

if not test -d "$_flag_handoff_dir"
    fail "Handoff directory does not exist: $_flag_handoff_dir"
end

if not test -d "$_flag_target_cwd"
    fail "Target working directory does not exist: $_flag_target_cwd"
end

set handoff_dir (path resolve -- "$_flag_handoff_dir")
if not set -q handoff_dir[1]
    fail "Could not resolve handoff directory: $_flag_handoff_dir"
end

set target_cwd (path resolve -- "$_flag_target_cwd")
if not set -q target_cwd[1]
    fail "Could not resolve target working directory: $_flag_target_cwd"
end

set bundle_archive "$handoff_dir/session.codex-session.tar.gz"
if not test -f "$bundle_archive"
    fail "Compressed bundle does not exist: $bundle_archive"
end
if test -L "$bundle_archive"
    fail "Compressed bundle must not be a symbolic link: $bundle_archive"
end

validate_archive "$bundle_archive"
or fail 'Compressed bundle failed structural safety checks.'

set extraction_dir (mktemp -d)
if not set -q extraction_dir[1]
    fail 'Could not create a temporary extraction directory.'
end

set local_archive "$extraction_dir/session.codex-session.tar.gz"
command cp "$bundle_archive" "$local_archive"
or begin
    cleanup_extraction "$extraction_dir"
    fail 'Could not copy the compressed bundle into secure temporary storage.'
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
    transcript.md \
    transcript.html \
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

if codex-session-exporter inspect "$imported_session_id" >/dev/null 2>&1
    cleanup_extraction "$extraction_dir"
    fail "A local Codex session already uses this ID: $imported_session_id"
end

codex-session-exporter import bundle "$bundle_dir" --target-cwd "$target_cwd"
set import_status $status

cleanup_extraction "$extraction_dir"

if test "$import_status" -ne 0
    exit "$import_status"
end

printf '%s\n' "Transcript: $handoff_dir/transcript.md"
if test -f "$handoff_dir/source.patch"
    printf '%s\n' "Tracked source patch: $handoff_dir/source.patch"
    printf '%s\n' 'Review it before applying with git apply --check.'
end

if test -s "$handoff_dir/source-status.txt"
    printf '%s\n' "Source status: $handoff_dir/source-status.txt"
end
