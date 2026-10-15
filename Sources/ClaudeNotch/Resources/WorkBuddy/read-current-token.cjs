'use strict';
// Current-access-token compatibility only. No account file, refresh token, network or disk writes.
const crypto = require('node:crypto');
const fs = require('node:fs');
const MAX = 32768;

function canonicalBase64(value, length) {
  if (typeof value !== 'string' || value.length > MAX) throw new Error('invalid');
  const bytes = Buffer.from(value, 'base64');
  if (bytes.toString('base64') !== value || (length !== undefined && bytes.length !== length)) throw new Error('invalid');
  return bytes;
}
function u32(value) { const bytes = Buffer.alloc(4); bytes.writeUInt32BE(value); return bytes; }
function sized(value) { const bytes = Buffer.from(value, 'utf8'); return Buffer.concat([u32(bytes.length), bytes]); }
function decodeCurrentToken(wrapper, payload) {
  if (!wrapper || Object.keys(wrapper).sort().join(',') !== '$wbEncrypted,envelope' || wrapper.$wbEncrypted !== 1) throw new Error('unsupported');
  if (!payload || payload.version !== 1) throw new Error('unsupported');
  const rawKey = canonicalBase64(payload.atRestSecretKey, 32);
  const nonzero = rawKey.some(value => value !== 0); rawKey.fill(0);
  if (!nonzero) throw new Error('unavailable');
  const key = crypto.createHash('sha256').update(payload.atRestSecretKey, 'utf8').digest();
  let plain;
  try {
    const envelope = JSON.parse(canonicalBase64(wrapper.envelope).toString('utf8'));
    if (Object.keys(envelope).sort().join(',') !== 'authTag,ciphertext,keyId,nonce,suite' || envelope.suite !== 1) throw new Error('unsupported');
    const keyID = crypto.createHash('sha256').update(key).digest('hex').slice(0, 16);
    if (envelope.keyId !== keyID) throw new Error('unavailable');
    const aad = Buffer.concat([Buffer.from('WB-AAD\0', 'ascii'), Buffer.from([1]), sized('WBEV1'), sized('sym-v1'), u32(1), sized(keyID), Buffer.from([2, 0, 0])]);
    const decipher = crypto.createDecipheriv('aes-256-gcm', key, canonicalBase64(envelope.nonce, 12), {authTagLength: 16});
    decipher.setAAD(aad); decipher.setAuthTag(canonicalBase64(envelope.authTag, 16));
    plain = Buffer.concat([decipher.update(canonicalBase64(envelope.ciphertext)), decipher.final()]);
    const token = plain.toString('utf8');
    if (!token || token.length > MAX || /[\x00-\x20\x7f]/.test(token) || !Buffer.from(token, 'utf8').equals(plain)) throw new Error('invalid');
    return token;
  } finally { key.fill(0); plain?.fill(0); }
}

if (require.main === module) {
  try {
    const chunks = []; let size = 0;
    while (true) {
      const chunk = Buffer.alloc(4096), count = fs.readSync(0, chunk, 0, chunk.length);
      if (!count) break;
      size += count; if (size > MAX) throw new Error('invalid');
      chunks.push(chunk.subarray(0, count));
    }
    const bytes = Buffer.concat(chunks);
    if (!bytes.length || bytes.length > MAX) throw new Error('invalid');
    const wrapper = JSON.parse(bytes.toString('utf8'));
    const payload = JSON.parse(process._linkedBinding('electron_browser_workbuddy_storage').loggerGet());
    const accessToken = decodeCurrentToken(wrapper, payload);
    // Private stdout pipe consumed in memory by the provider; never forwarded to a log.
    process.stdout.write(JSON.stringify({accessToken}));
  } catch { process.stdout.write('{"error":"unavailable"}'); process.exitCode = 1; }
}
module.exports = {decodeCurrentToken};
