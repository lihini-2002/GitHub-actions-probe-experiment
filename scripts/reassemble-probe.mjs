// Reassemble the npm-probing-package install report from OpenSSF Package
// Analysis file-write results.
//
// OpenSSF records each write() the analyzed package makes inside the gVisor
// sandbox. The sandbox filesystem is discarded when analysis ends, so the
// report file itself never reaches the runner, but the *contents* of every
// write() survive in the file-write results:
//
//   results.json            maps each written path to an ordered list of
//                           WriteBufferId values (one per write() call).
//   write_buffers_/<id>.json  holds the captured buffer for that id, as the
//                           gVisor strace logged it: the bytes between the
//                           quotes of the strace `write(... "..." ...)` line,
//                           still Go-quote escaped (\n, \", \xHH, ...).
//
// For every path that looks like the probe's report (install-<uuid>.json, or
// its .tmp staging name), we concatenate its buffers in write order, undo the
// Go escaping, and write the result to the output directory.
//
// Usage: node reassemble-probe.mjs <results.json> <buffers-dir> <out-dir>

import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { join, basename } from 'node:path';

const [, , resultsPath, buffersDir, outDir] = process.argv;

if (!resultsPath || !buffersDir || !outDir) {
  console.error('Usage: node reassemble-probe.mjs <results.json> <buffers-dir> <out-dir>');
  process.exit(2);
}

const REPORT_PATH = /\/install-[0-9a-fA-F-]+\.json(\.tmp)?$/;

// Decode a Go double-quoted string body (no surrounding quotes) into raw bytes.
function unescapeGoString(text) {
  const out = [];
  const pushRune = (cp) => {
    for (const b of Buffer.from(String.fromCodePoint(cp), 'utf8')) out.push(b);
  };
  for (let i = 0; i < text.length; i += 1) {
    const ch = text[i];
    if (ch !== '\\') {
      pushRune(text.codePointAt(i));
      if (text.codePointAt(i) > 0xffff) i += 1; // surrogate pair consumed
      continue;
    }
    const next = text[++i];
    switch (next) {
      case 'n': out.push(0x0a); break;
      case 't': out.push(0x09); break;
      case 'r': out.push(0x0d); break;
      case 'a': out.push(0x07); break;
      case 'b': out.push(0x08); break;
      case 'f': out.push(0x0c); break;
      case 'v': out.push(0x0b); break;
      case '\\': out.push(0x5c); break;
      case '"': out.push(0x22); break;
      case "'": out.push(0x27); break;
      case 'x': {
        out.push(parseInt(text.slice(i + 1, i + 3), 16));
        i += 2;
        break;
      }
      case 'u': {
        pushRune(parseInt(text.slice(i + 1, i + 5), 16));
        i += 4;
        break;
      }
      case 'U': {
        pushRune(parseInt(text.slice(i + 1, i + 9), 16));
        i += 8;
        break;
      }
      default: {
        if (next >= '0' && next <= '7') {
          // Octal escape (\NNN); strconv.Quote does not emit these, handled for safety.
          const oct = text.slice(i, i + 3);
          out.push(parseInt(oct, 8));
          i += 2;
        } else {
          out.push(next.charCodeAt(0));
        }
      }
    }
  }
  return Buffer.from(out);
}

const results = JSON.parse(readFileSync(resultsPath, 'utf8'));
const phases = results.Analysis ?? {};

mkdirSync(outDir, { recursive: true });

let recovered = 0;
for (const [phase, entries] of Object.entries(phases)) {
  if (!Array.isArray(entries)) continue;
  for (const entry of entries) {
    const path = entry.Path ?? '';
    if (!REPORT_PATH.test(path)) continue;

    const chunks = [];
    let missing = false;
    for (const info of entry.WriteInfo ?? []) {
      const bufferFile = join(buffersDir, `${info.WriteBufferId}.json`);
      if (!existsSync(bufferFile)) {
        console.error(`WARN: missing write buffer ${info.WriteBufferId} for ${path}`);
        missing = true;
        continue;
      }
      chunks.push(unescapeGoString(readFileSync(bufferFile, 'utf8')));
    }

    const data = Buffer.concat(chunks);
    const outName = basename(path).replace(/\.tmp$/, '');
    const outPath = join(outDir, outName);
    writeFileSync(outPath, data);
    recovered += 1;

    let note = `${data.length} bytes`;
    try {
      const parsed = JSON.parse(data.toString('utf8'));
      const props = parsed.properties ? Object.keys(parsed.properties).length : 0;
      note += `, valid JSON, ${props} properties`;
    } catch {
      note += ', WARNING: not valid JSON (likely still truncated)';
    }
    if (missing) note += ', WARNING: some buffers were missing';
    console.log(`Recovered ${phase} report -> ${outPath} (${note})`);
  }
}

if (recovered === 0) {
  console.log('No install-*.json write buffers found in file-write results.');
}
