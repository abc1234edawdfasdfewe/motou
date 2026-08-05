#!/usr/bin/env node
'use strict';

const assert = require('assert');
const fs = require('fs');
const vm = require('vm');

const source = fs.readFileSync('app/src/main/assets/web/document-import.js', 'utf8');
const appSource = fs.readFileSync('app/src/main/assets/web/app.js', 'utf8');
const sandbox = {
  window: {},
  TextDecoder,
  Uint8Array,
  ArrayBuffer,
  Promise,
  Error,
  Number,
  Math,
  String,
  RegExp,
  Object,
  Array,
};
vm.runInNewContext(source, sandbox, { filename: 'document-import.js' });

const api = sandbox.window.MoTouDocumentImport;
const test = api._test;
let passed = 0;

function check(name, fn) {
  return Promise.resolve().then(fn).then(() => {
    passed++;
    console.log('PASS', name);
  });
}

function filledRow(length, prefix) {
  return Array.from({ length }, (_, index) => `${prefix}${index}`);
}

function makeZip(entries, options = {}) {
  const localParts = [];
  const centralParts = [];
  let localOffset = 0;
  entries.forEach((entry, index) => {
    const name = Buffer.from(entry.name || `entry-${index}`);
    const data = Buffer.from(entry.data || []);
    const packedSize = entry.packedSize == null ? data.length : entry.packedSize;
    const expandedSize = entry.expandedSize == null ? data.length : entry.expandedSize;
    const flags = entry.flags || 0;
    const method = entry.method || 0;
    assert.ok(packedSize <= data.length || packedSize === 0, 'synthetic ZIP only stores provided or zero-byte payloads');

    const local = Buffer.alloc(30 + name.length + packedSize);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(flags, 6);
    local.writeUInt16LE(method, 8);
    local.writeUInt32LE(packedSize >>> 0, 18);
    local.writeUInt32LE(expandedSize >>> 0, 22);
    local.writeUInt16LE(name.length, 26);
    name.copy(local, 30);
    if (packedSize) data.copy(local, 30 + name.length, 0, packedSize);
    localParts.push(local);

    const central = Buffer.alloc(46 + name.length);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(20, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(flags, 8);
    central.writeUInt16LE(method, 10);
    central.writeUInt32LE(packedSize >>> 0, 20);
    central.writeUInt32LE(expandedSize >>> 0, 24);
    central.writeUInt16LE(name.length, 28);
    central.writeUInt32LE(localOffset >>> 0, 42);
    name.copy(central, 46);
    centralParts.push(central);
    localOffset += local.length;
  });

  const central = Buffer.concat(centralParts);
  const declaredCount = options.declaredCount == null ? entries.length : options.declaredCount;
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(declaredCount, 8);
  eocd.writeUInt16LE(declaredCount, 10);
  eocd.writeUInt32LE(central.length, 12);
  eocd.writeUInt32LE(localOffset, 16);
  return new Uint8Array(Buffer.concat([...localParts, central, eocd]));
}

function fakeFile(name, type, bytes, size) {
  const exact = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
  return { name, type, size: size == null ? bytes.byteLength : size, arrayBuffer() { return Promise.resolve(exact); } };
}

function nestedPptRecords(depth) {
  let payload = Buffer.alloc(8);
  payload.writeUInt16LE(0x000f, 0);
  for (let index = 0; index < depth; index++) {
    const record = Buffer.alloc(8 + payload.length);
    record.writeUInt16LE(0x000f, 0);
    record.writeUInt16LE(1, 2);
    record.writeUInt32LE(payload.length, 4);
    payload.copy(record, 8);
    payload = record;
  }
  return new Uint8Array(payload);
}

function flatPptRecords(count) {
  const records = Buffer.alloc(count * 8);
  for (let index = 0; index < count; index++) records.writeUInt16LE(1, index * 8 + 2);
  return new Uint8Array(records);
}

async function main() {
  await check('large worksheet !ref is clamped before conversion', () => {
    const plan = test.clampDecodedSheetRange({
      s: { r: 9, c: 25 },
      e: { r: 1048575, c: 16383 },
    });
    assert.deepStrictEqual(JSON.parse(JSON.stringify(plan.range)), {
      s: { r: 9, c: 25 },
      e: { r: 3008, c: 224 },
    });
    assert.strictEqual(plan.truncated, true);
  });

  await check('spreadsheet extraction preserves the leading 60000 cells across sheets', () => {
    const firstRows = Array.from({ length: 299 }, (_, row) => filledRow(200, `A${row}-`));
    firstRows.push(filledRow(150, 'A-last-')); // 59,950 cells
    const calls = [];
    const workbook = {
      SheetNames: ['Big', 'Second'],
      Sheets: {
        Big: { '!ref': 'A1:XFD1048576', __rows: firstRows },
        Second: { '!ref': 'A1:GR1', __rows: [filledRow(200, 'B-')] },
      },
    };
    const utils = {
      decode_range(ref) {
        if (ref === 'A1:XFD1048576') return { s: { r: 0, c: 0 }, e: { r: 1048575, c: 16383 } };
        if (ref === 'A1:GR1') return { s: { r: 0, c: 0 }, e: { r: 0, c: 199 } };
        throw new Error(`unexpected range ${ref}`);
      },
      sheet_to_json(sheet, options) {
        calls.push(JSON.parse(JSON.stringify(options.range)));
        return sheet.__rows;
      },
    };

    const result = test.extractSpreadsheetGrid(workbook, utils);
    assert.strictEqual(calls.length, 2);
    assert.deepStrictEqual(calls[0], { s: { r: 0, c: 0 }, e: { r: 2999, c: 199 } });
    assert.strictEqual(result.sheets.length, 2);
    assert.strictEqual(result.sheets[0].rows.length, 300);
    assert.strictEqual(result.sheets[1].rows.length, 1);
    assert.strictEqual(result.sheets[1].rows[0].length, 50);
    assert.strictEqual(result.usedCells, 60000);
    assert.strictEqual(result.remainingCells, 0);
    assert.strictEqual(result.truncated, true);
  });

  await check('a first sheet over 60000 cells is retained instead of discarded', () => {
    const rows = Array.from({ length: 301 }, (_, row) => filledRow(200, `R${row}-`));
    const workbook = {
      SheetNames: ['Only'],
      Sheets: { Only: { '!ref': 'A1:GR301', __rows: rows } },
    };
    const utils = {
      decode_range() { return { s: { r: 0, c: 0 }, e: { r: 300, c: 199 } }; },
      sheet_to_json(sheet) { return sheet.__rows; },
    };
    const result = test.extractSpreadsheetGrid(workbook, utils);
    assert.strictEqual(result.sheets.length, 1);
    assert.strictEqual(result.sheets[0].rows.length, 300);
    assert.strictEqual(result.usedCells, 60000);
    assert.strictEqual(result.truncated, true);
  });

  await check('MIME-only Markdown, DOCX, text and KF8 files are recognized', () => {
    assert.strictEqual(api.isReadableFile({ name: 'document', type: 'text/x-markdown' }), true);
    assert.strictEqual(api.isReadableFile({ name: 'document', type: 'text/md' }), true);
    assert.strictEqual(api.isReadableFile({ name: 'document', type: 'application/markdown' }), true);
    assert.strictEqual(api.isReadableFile({ name: 'document', type: 'text/plain' }), true);
    assert.strictEqual(api.isReadableFile({ name: 'document', type: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' }), true);
    assert.strictEqual(api.isReadableFile({ name: 'document', type: 'application/x-mobi8-ebook' }), true);
  });

  await check('oversized MIME-only Markdown rejects before reading bytes', async () => {
    let reads = 0;
    const promise = api.importFile({
      name: 'document',
      type: 'text/x-markdown',
      size: test.limits.maxFileBytes + 1,
      arrayBuffer() { reads++; return Promise.resolve(new ArrayBuffer(0)); },
    });
    assert.strictEqual(typeof promise.then, 'function');
    await assert.rejects(promise, error => error && error.code === 'too-large');
    assert.strictEqual(reads, 0);
  });

  await check('oversized DOCX rejects before arrayBuffer and Mammoth', async () => {
    let reads = 0;
    let mammothCalls = 0;
    sandbox.window.mammoth = { convertToHtml() { mammothCalls++; return Promise.resolve({ value: '<p>x</p>' }); } };
    await assert.rejects(api.importFile({
      name: 'large.docx',
      type: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      size: test.limits.maxFileBytes + 1,
      arrayBuffer() { reads++; return Promise.resolve(new ArrayBuffer(0)); },
    }), error => error && error.code === 'too-large');
    assert.strictEqual(reads, 0);
    assert.strictEqual(mammothCalls, 0);
  });

  await check('all local semantic files use the bounded document importer', () => {
    assert.ok(!/function\s+castDocx\b/.test(appSource));
    assert.ok(!/function\s+readTextFile\b/.test(appSource));
    assert.ok(!/readAsText\s*\(/.test(appSource));
    assert.ok(/MoTouDocumentImport\.isReadableFile\(f\)/.test(appSource));
  });

  await check('ZIP preflight accepts exact expansion limits and rejects the next byte', () => {
    const one = test.limits.maxZipEntryUnzippedBytes;
    const remainder = test.limits.maxUnzippedBytes - one * 6;
    const exact = makeZip([
      ...Array.from({ length: 6 }, (_, index) => ({ name: `part-${index}`, method: 8, expandedSize: one })),
      { name: 'remainder', method: 8, expandedSize: remainder },
    ]);
    const stats = test.preflightZipCentralDirectory(exact, 'TEST');
    assert.strictEqual(stats.entries, 7);
    assert.strictEqual(stats.expandedBytes, test.limits.maxUnzippedBytes);

    const singleTooLarge = makeZip([{ name: 'bomb', method: 8, expandedSize: one + 1 }]);
    assert.throws(() => test.preflightZipCentralDirectory(singleTooLarge, 'TEST'), error => error && error.code === 'too-large');
    const totalTooLarge = makeZip([
      ...Array.from({ length: 6 }, (_, index) => ({ name: `part-${index}`, method: 8, expandedSize: one })),
      { name: 'remainder', method: 8, expandedSize: remainder + 1 },
    ]);
    assert.throws(() => test.preflightZipCentralDirectory(totalTooLarge, 'TEST'), error => error && error.code === 'too-large');
  });

  await check('ZIP preflight rejects excessive entries, encryption and malformed directories', () => {
    const tooMany = makeZip([{ name: 'one' }], { declaredCount: test.limits.maxZipEntries + 1 });
    assert.throws(() => test.preflightZipCentralDirectory(tooMany, 'TEST'), error => error && error.code === 'too-large');
    const encrypted = makeZip([{ name: 'secret', flags: 1 }]);
    assert.throws(() => test.preflightZipCentralDirectory(encrypted, 'TEST'), error => error && error.code === 'encrypted');
    const malformed = makeZip([{ name: 'broken' }]).slice(0, -1);
    assert.throws(() => test.preflightZipCentralDirectory(malformed, 'TEST'), error => error && error.code === 'corrupt');
  });

  await check('DOCX and XLSX bombs are rejected before third-party parsers', async () => {
    const bomb = makeZip([{ name: 'payload.xml', method: 8, expandedSize: test.limits.maxZipEntryUnzippedBytes + 1 }]);
    let mammothCalls = 0;
    let sheetCalls = 0;
    sandbox.window.mammoth = { convertToHtml() { mammothCalls++; return Promise.resolve({ value: '<p>x</p>' }); } };
    sandbox.window.XLSX = { read() { sheetCalls++; return {}; }, utils: {} };
    await assert.rejects(api.importFile(fakeFile('bomb.docx', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', bomb)),
      error => error && error.code === 'too-large');
    await assert.rejects(api.importFile(fakeFile('bomb.xlsx', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', bomb)),
      error => error && error.code === 'too-large');
    assert.strictEqual(mammothCalls, 0);
    assert.strictEqual(sheetCalls, 0);
  });

  await check('imported image sources only allow supported inline base64 data', () => {
    assert.strictEqual(test.safeImageSrc('https://example.com/tracker.png'), '');
    assert.strictEqual(test.safeImageSrc('http://192.168.1.1/private.png'), '');
    assert.strictEqual(test.safeImageSrc('blob:https://example.com/id'), '');
    assert.strictEqual(test.safeImageSrc('data:image/svg+xml;base64,PHN2Zz4='), '');
    assert.strictEqual(test.safeImageSrc('data:image/png;base64,iVBORw0KGgo='), 'data:image/png;base64,iVBORw0KGgo=');
  });

  await check('EPUB encryption permits only standard font obfuscation', () => {
    assert.strictEqual(test.isAllowedEpubFontObfuscation('http://www.idpf.org/2008/embedding', 'fonts/book.ttf'), true);
    assert.strictEqual(test.isAllowedEpubFontObfuscation('http://ns.adobe.com/pdf/enc#RC', 'fonts/book.otf?x=1'), true);
    assert.strictEqual(test.isAllowedEpubFontObfuscation('urn:unknown', 'fonts/book.ttf'), false);
    assert.strictEqual(test.isAllowedEpubFontObfuscation('http://www.idpf.org/2008/embedding', 'chapters/one.xhtml'), false);
    assert.strictEqual(test.hasEpubRightsProtection({ 'META-INF/rights.xml': new Uint8Array([1]) }), true);
    assert.strictEqual(test.hasEpubRightsProtection({ 'META-INF/container.xml': new Uint8Array([1]) }), false);
  });

  await check('legacy PPT fallback rejects excessive recursive record nesting', () => {
    assert.throws(() => test.fallbackPptText(nestedPptRecords(70)), error => error && error.code === 'too-large');
  });

  await check('legacy PPT encryption preflight bounds recursion and total records', () => {
    assert.throws(() => test.pptContainsCryptRecord(nestedPptRecords(70)), error => error && error.code === 'too-large');
    assert.throws(() => test.pptContainsCryptRecord(flatPptRecords(test.limits.maxPptRecords + 1)),
      error => error && error.code === 'too-large');
    const crypt = flatPptRecords(1);
    crypt[2] = 0x14;
    crypt[3] = 0x2f;
    assert.strictEqual(test.pptContainsCryptRecord(crypt), true);
  });

  await check('trimResult reserves space for its notice within the 4 Mi character cap', () => {
    const limit = test.limits.maxResultChars;
    const exact = 'x'.repeat(limit);
    assert.strictEqual(test.trimResult(exact), exact);
    const trimmed = test.trimResult(`${exact}overflow`);
    assert.ok(trimmed.includes('内容过长'));
    assert.ok(trimmed.length <= limit, `${trimmed.length} should be <= ${limit}`);
  });

  console.log(`\n${passed} document-import checks passed`);
}

main().catch(error => {
  console.error(error.stack || error);
  process.exit(1);
});
