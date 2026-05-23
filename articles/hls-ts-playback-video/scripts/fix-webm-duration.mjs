import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const input = resolve(process.argv[2] || "articles/hls-ts-playback-video/renders/hls-ts-playback.webm");
const durationSeconds = Number(process.argv[3] || 124);

function indexOfBytes(buffer, bytes, start = 0, end = buffer.length) {
  outer:
  for (let i = start; i <= end - bytes.length; i++) {
    for (let j = 0; j < bytes.length; j++) {
      if (buffer[i + j] !== bytes[j])
        continue outer;
    }
    return i;
  }
  return -1;
}

function readVint(buffer, offset) {
  const first = buffer[offset];
  let mask = 0x80;
  let length = 1;
  while (length <= 8 && !(first & mask)) {
    mask >>= 1;
    length++;
  }
  if (length > 8)
    throw new Error(`Invalid EBML vint at ${offset}`);

  let value = first & ~mask;
  let allValueBitsSet = value === (mask - 1);
  for (let i = 1; i < length; i++) {
    value = value * 256 + buffer[offset + i];
    allValueBitsSet &&= buffer[offset + i] === 0xff;
  }
  return { length, value, unknown: allValueBitsSet };
}

function writeVint(value, length) {
  const max = 2 ** (7 * length) - 2;
  if (value > max)
    throw new Error(`Value ${value} does not fit in ${length}-byte EBML vint`);
  const out = Buffer.alloc(length);
  for (let i = length - 1; i >= 0; i--) {
    out[i] = value & 0xff;
    value = Math.floor(value / 256);
  }
  out[0] |= 1 << (8 - length);
  return out;
}

function durationElement(durationMs) {
  const out = Buffer.alloc(11);
  out[0] = 0x44;
  out[1] = 0x89;
  out[2] = 0x88;
  out.writeDoubleBE(durationMs, 3);
  return out;
}

const original = await readFile(input);
const infoId = Buffer.from([0x15, 0x49, 0xa9, 0x66]);
const durationId = Buffer.from([0x44, 0x89]);
const infoOffset = indexOfBytes(original, infoId);
if (infoOffset < 0)
  throw new Error("Matroska Info element not found");

const sizeOffset = infoOffset + infoId.length;
const infoSize = readVint(original, sizeOffset);
if (infoSize.unknown)
  throw new Error("Cannot patch Info element with unknown size");

const contentStart = sizeOffset + infoSize.length;
const contentEnd = contentStart + infoSize.value;
const existingDuration = indexOfBytes(original, durationId, contentStart, contentEnd);
const duration = durationElement(durationSeconds * 1000);

let output;
if (existingDuration >= 0) {
  const durationSize = readVint(original, existingDuration + durationId.length);
  if (durationSize.length !== 1 || durationSize.value !== 8)
    throw new Error("Existing Duration element has unexpected size");
  output = Buffer.from(original);
  duration.copy(output, existingDuration);
} else {
  const newInfoSize = infoSize.value + duration.length;
  const newSize = writeVint(newInfoSize, infoSize.length);
  output = Buffer.concat([
    original.subarray(0, sizeOffset),
    newSize,
    original.subarray(contentStart, contentEnd),
    duration,
    original.subarray(contentEnd)
  ]);
}

await writeFile(input, output);
console.log(`Patched ${input} with Duration=${durationSeconds}s`);
