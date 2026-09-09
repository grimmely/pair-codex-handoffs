# Both send and receive enforce the same raw archive structure.
function pair_handoff_compress_bundle --argument-names staging_dir archive_path
    # ustar avoids extended headers; copyfile metadata is not session data.
    env COPYFILE_DISABLE=1 tar --format=ustar -C "$staging_dir" -czf "$archive_path" session.codex-session
end

function pair_handoff_validate_archive --argument-names archive_path
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
