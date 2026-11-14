'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { loadConfig, ConfigError } = require('../src/config');
const { testEnv } = require('./helpers');

test('loads a valid configuration', () => {
  const cfg = loadConfig(testEnv({ PORT: '8080' }));
  assert.equal(cfg.port, 8080);
  assert.equal(cfg.metricsPort, 9464);
  assert.equal(cfg.phiKey.length, 32);
  assert.ok(Object.isFrozen(cfg));
});

for (const name of ['JWT_SECRET', 'PHI_ENCRYPTION_KEY', 'DOCTOR_PASSWORD', 'NURSE_PASSWORD', 'RECEPTIONIST_PASSWORD']) {
  test(`refuses to start without ${name} (no hardcoded fallback)`, () => {
    const env = testEnv();
    delete env[name];
    assert.throws(() => loadConfig(env), (err) => err instanceof ConfigError && err.message.includes(name));
  });
}

test('rejects a short JWT secret', () => {
  assert.throws(() => loadConfig(testEnv({ JWT_SECRET: 'too-short' })), /at least 32/);
});

test('rejects an encryption key that is not 32 bytes', () => {
  const key = Buffer.alloc(16, 1).toString('base64');
  assert.throws(() => loadConfig(testEnv({ PHI_ENCRYPTION_KEY: key })), /32 bytes/);
});

test('rejects weak staff passwords', () => {
  assert.throws(() => loadConfig(testEnv({ NURSE_PASSWORD: 'password' })), /NURSE_PASSWORD/);
});

test('rejects an invalid port', () => {
  assert.throws(() => loadConfig(testEnv({ PORT: 'abc' })), /PORT/);
});
