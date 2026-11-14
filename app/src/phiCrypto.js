'use strict';

// Field-level encryption for Protected Health Information (PHI).
//
// AES-256-GCM gives confidentiality AND integrity: if anyone edits a stored
// ciphertext, decryption fails instead of returning tampered data. The record
// id is bound in as "additional authenticated data", so an attacker cannot
// copy patient A's encrypted blob onto patient B's record either.

const crypto = require('node:crypto');

const ALGORITHM = 'aes-256-gcm';
const IV_BYTES = 12; // 96-bit nonce, the recommended size for GCM
const VERSION = 'v1';

function createPhiCipher(key) {
  if (!Buffer.isBuffer(key) || key.length !== 32) {
    throw new Error('PHI key must be a 32-byte Buffer');
  }

  function encrypt(plainObject, recordId) {
    const iv = crypto.randomBytes(IV_BYTES);
    const cipher = crypto.createCipheriv(ALGORITHM, key, iv);
    cipher.setAAD(Buffer.from(String(recordId), 'utf8'));
    const ciphertext = Buffer.concat([
      cipher.update(JSON.stringify(plainObject), 'utf8'),
      cipher.final(),
    ]);
    const tag = cipher.getAuthTag();
    return [VERSION, iv.toString('base64'), tag.toString('base64'), ciphertext.toString('base64')].join(':');
  }

  function decrypt(blob, recordId) {
    const parts = String(blob).split(':');
    if (parts.length !== 4 || parts[0] !== VERSION) {
      throw new Error('Unsupported PHI ciphertext format');
    }
    const [, ivB64, tagB64, dataB64] = parts;
    const decipher = crypto.createDecipheriv(ALGORITHM, key, Buffer.from(ivB64, 'base64'));
    decipher.setAAD(Buffer.from(String(recordId), 'utf8'));
    decipher.setAuthTag(Buffer.from(tagB64, 'base64'));
    const plaintext = Buffer.concat([
      decipher.update(Buffer.from(dataB64, 'base64')),
      decipher.final(), // throws if the ciphertext or tag was modified
    ]);
    return JSON.parse(plaintext.toString('utf8'));
  }

  return { encrypt, decrypt };
}

module.exports = { createPhiCipher };
