'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const {spawnSync} = require('node:child_process');
const path = require('node:path');
const helper = path.resolve(__dirname, '../../Sources/ClaudeNotch/Resources/WorkBuddy/read-current-token.cjs');
const {decodeCurrentToken} = require(helper);

// Synthetic credentials only: no installed account or native storage is accessed here.
function fixture(token = 'fixture-current-token') {
  const payload = {version: 1, atRestSecretKey: Buffer.alloc(32, 7).toString('base64')};
  const key = crypto.createHash('sha256').update(payload.atRestSecretKey).digest();
  const keyId = crypto.createHash('sha256').update(key).digest('hex').slice(0, 16);
  const u32 = value => { const bytes = Buffer.alloc(4); bytes.writeUInt32BE(value); return bytes; };
  const sized = value => Buffer.concat([u32(Buffer.byteLength(value)), Buffer.from(value)]);
  const aad = Buffer.concat([Buffer.from('WB-AAD\0'), Buffer.from([1]), sized('WBEV1'), sized('sym-v1'), u32(1), sized(keyId), Buffer.from([2, 0, 0])]);
  const nonce = Buffer.alloc(12, 3);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, nonce);
  cipher.setAAD(aad);
  const ciphertext = Buffer.concat([cipher.update(token), cipher.final()]);
  const envelope = {suite: 1, keyId, nonce: nonce.toString('base64'), authTag: cipher.getAuthTag().toString('base64'), ciphertext: ciphertext.toString('base64')};
  const wrap = value => ({$wbEncrypted: 1, envelope: Buffer.from(JSON.stringify(value)).toString('base64')});
  return {payload, envelope, wrap, wrapper: wrap(envelope)};
}

test('decodes the authenticated current token', () => {
  const {payload, wrapper} = fixture();
  assert.equal(decodeCurrentToken(wrapper, payload), 'fixture-current-token');
});
test('rejects tampered ciphertext and wrong account key', () => {
  const {payload, envelope, wrap, wrapper} = fixture();
  const changed = Buffer.from(envelope.ciphertext, 'base64'); changed[0] ^= 1;
  assert.throws(() => decodeCurrentToken(wrap({...envelope, ciphertext: changed.toString('base64')}), payload));
  assert.throws(() => decodeCurrentToken(wrapper, {...payload, atRestSecretKey: Buffer.alloc(32, 8).toString('base64')}));
});
test('rejects unsupported protection, malformed envelopes and invalid tokens', () => {
  const {payload, envelope, wrap, wrapper} = fixture();
  for (const candidate of [
    {...wrapper, scheme: 'asym-v1'}, {...wrapper, $wbEncrypted: 2},
    {...wrapper, envelope: 'not base64'}, wrap({...envelope, suite: 2}),
    wrap({...envelope, nonce: Buffer.alloc(11).toString('base64')}),
    wrap({...envelope, authTag: Buffer.alloc(15).toString('base64')})
  ]) assert.throws(() => decodeCurrentToken(candidate, payload));
  for (const value of ['', 'token\nheader']) {
    const invalid = fixture(value);
    assert.throws(() => decodeCurrentToken(invalid.wrapper, invalid.payload));
  }
});
test('CLI failure returns only a generic error', () => {
  const result = spawnSync(process.execPath, [helper], {input: '{"fixtureSecret":"must-not-echo"}', encoding: 'utf8'});
  assert.equal(result.status, 1);
  assert.equal(result.stdout, '{"error":"unavailable"}');
  assert.equal(result.stderr, '');
});
