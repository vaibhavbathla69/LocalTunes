const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { sha256 } = require('../LocalTunes/Resources/Transfer.js');
for (const size of [0, 1, 3, 55, 56, 63, 64, 65, 1000, 1048576]) {
  const data = size === 3 ? Buffer.from('abc') : crypto.randomBytes(size);
  const bytes = data.buffer.slice(data.byteOffset, data.byteOffset + data.length);
  assert.equal(sha256(bytes), crypto.createHash('sha256').update(data).digest('hex'));
}
console.log('Browser chunk SHA-256: 10 vectors match Node crypto.');
