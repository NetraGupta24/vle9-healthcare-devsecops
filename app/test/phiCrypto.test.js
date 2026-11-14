'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { createPhiCipher } = require('../src/phiCrypto');
const { createPatientStore } = require('../src/store');
const { VALID_PATIENT } = require('./helpers');

const key = crypto.randomBytes(32);

test('encrypt/decrypt round trip', () => {
  const c = createPhiCipher(key);
  const blob = c.encrypt({ diagnosis: 'Asthma' }, 'id-1');
  assert.match(blob, /^v1:/);
  assert.deepEqual(c.decrypt(blob, 'id-1'), { diagnosis: 'Asthma' });
});

test('each encryption uses a fresh IV', () => {
  const c = createPhiCipher(key);
  assert.notEqual(c.encrypt({ a: 1 }, 'x'), c.encrypt({ a: 1 }, 'x'));
});

test('tampered ciphertext is rejected (GCM integrity)', () => {
  const c = createPhiCipher(key);
  const parts = c.encrypt({ diagnosis: 'Asthma' }, 'id-1').split(':');
  const data = Buffer.from(parts[3], 'base64');
  data[0] ^= 0xff;
  parts[3] = data.toString('base64');
  assert.throws(() => c.decrypt(parts.join(':'), 'id-1'));
});

test('ciphertext cannot be moved to another record (AAD binding)', () => {
  const c = createPhiCipher(key);
  const blob = c.encrypt({ diagnosis: 'Asthma' }, 'patient-a');
  assert.throws(() => c.decrypt(blob, 'patient-b'));
});

test('a different key cannot decrypt', () => {
  const blob = createPhiCipher(key).encrypt({ a: 1 }, 'x');
  assert.throws(() => createPhiCipher(crypto.randomBytes(32)).decrypt(blob, 'x'));
});

test('rejects keys of the wrong size', () => {
  assert.throws(() => createPhiCipher(Buffer.alloc(16)));
});

test('store keeps no plaintext PHI in memory', () => {
  const store = createPatientStore(createPhiCipher(key));
  const { id } = store.create({ ...VALID_PATIENT, diagnosis: 'Migraine' }, 'tester');
  const raw = JSON.stringify(store.rawRecord(id));
  for (const secret of ['Rohan', 'Verma', '499912345678', '+919811112222', 'Migraine']) {
    assert.ok(!raw.includes(secret), `plaintext "${secret}" found in stored record`);
  }
  assert.equal(store.get(id).diagnosis, 'Migraine');
});
