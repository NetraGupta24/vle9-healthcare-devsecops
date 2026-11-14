'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const request = require('supertest');
const { buildApp, tokenFor } = require('./helpers');
const { createMetricsServer } = require('../src/server');

test('health and readiness endpoints', async () => {
  const { agent } = await buildApp();
  assert.deepEqual((await agent.get('/healthz')).body, { status: 'ok' });
  assert.equal((await agent.get('/readyz')).body.patients, 4);
});

test('security headers are set on every response', async () => {
  const { agent } = await buildApp();
  for (const path of ['/', '/healthz', '/api/patients', '/nope']) {
    const res = await agent.get(path);
    assert.match(res.headers['content-security-policy'], /default-src 'self'/);
    assert.match(res.headers['content-security-policy'], /frame-ancestors 'none'/);
    assert.equal(res.headers['x-content-type-options'], 'nosniff');
    assert.equal(res.headers['x-frame-options'], 'SAMEORIGIN');
    assert.equal(res.headers['cache-control'], 'no-store');
    assert.equal(res.headers['referrer-policy'], 'no-referrer');
    assert.ok(res.headers['strict-transport-security']);
    assert.ok(res.headers['permissions-policy']);
    assert.equal(res.headers['x-powered-by'], undefined);
  }
});

test('serves the web UI', async () => {
  const { agent } = await buildApp();
  const res = await agent.get('/');
  assert.equal(res.status, 200);
  assert.match(res.text, /MedSecure/);
  assert.doesNotMatch(res.text, /<script>/); // no inline scripts (CSP friendly)
  // Regression (found by OWASP ZAP rule 10024): a form without method="post"
  // would put passwords/PHI into the URL if the JavaScript failed to load.
  const forms = res.text.match(/<form\b[^>]*>/g);
  assert.ok(forms.length >= 3);
  for (const tag of forms) assert.match(tag, /method="post"/, tag);
});

test('malformed JSON and oversized bodies are handled safely', async () => {
  const { agent } = await buildApp();
  const bad = await agent.post('/api/auth/login').set('Content-Type', 'application/json').send('{"username":');
  assert.equal(bad.status, 400);
  assert.deepEqual(bad.body, { error: 'Malformed JSON' });
  const big = await agent.post('/api/auth/login').send({ username: 'a', password: 'x'.repeat(20_000) });
  assert.equal(big.status, 413);
});

test('unknown routes return JSON 404 without stack traces', async () => {
  const { agent } = await buildApp();
  const res = await agent.get('/api/does-not-exist');
  assert.equal(res.status, 404);
  assert.deepEqual(res.body, { error: 'Not found' });
});

test('alerting counters exist at 0 before the first event (so increase() can fire)', async () => {
  const { metrics } = await buildApp();
  const text = await metrics.register.metrics();
  for (const series of [
    'auth_login_failures_total{reason="bad_credentials"',
    'auth_unauthorized_requests_total{reason="forbidden_role"',
    'phi_records_accessed_total{action="read",role="doctor"',
    'phi_records_accessed_total{action="read",role="receptionist"',
  ]) {
    assert.ok(text.includes(series), `missing pre-initialised series ${series}`);
  }
});

test('metrics server exposes security metrics and uses route templates', async () => {
  const { agent, metrics } = await buildApp();
  await agent.get('/api/patients'); // unauthenticated
  const token = await tokenFor(agent, 'doctor');
  await agent.get('/api/patients/7d444840-9dc0-41c1-a6a5-6f9c1b3d8a11').set('Authorization', `Bearer ${token}`);
  const res = await request(createMetricsServer(metrics.register)).get('/metrics');
  assert.equal(res.status, 200);
  for (const name of ['auth_login_failures_total', 'auth_unauthorized_requests_total', 'phi_records_accessed_total',
    'http_requests_total', 'process_cpu_seconds_total']) {
    assert.match(res.text, new RegExp(name));
  }
  assert.match(res.text, /route="\/api\/patients\/:id"/);
  assert.doesNotMatch(res.text, /7d444840/); // no ids in labels
  assert.equal((await request(createMetricsServer(metrics.register)).get('/other')).status, 404);
});
