'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const jwt = require('jsonwebtoken');
const { buildApp, tokenFor, PASSWORDS } = require('./helpers');

async function metricValue(metrics, name, labels) {
  const m = await metrics.register.getSingleMetric(name).get();
  const v = m.values.find((x) => Object.entries(labels).every(([k, val]) => x.labels[k] === val));
  return v ? v.value : 0;
}

test('valid login returns a short-lived HS256 token', async () => {
  const { agent, config } = await buildApp();
  const res = await agent.post('/api/auth/login').send({ username: 'dr.mehta', password: PASSWORDS.doctor });
  assert.equal(res.status, 200);
  assert.equal(res.body.user.role, 'doctor');
  const decoded = jwt.verify(res.body.token, config.jwtSecret, { algorithms: ['HS256'] });
  assert.equal(decoded.sub, 'dr.mehta');
  assert.equal(decoded.exp - decoded.iat, 900);
});

test('wrong password and unknown user get the same generic 401', async () => {
  const { agent, metrics } = await buildApp();
  const a = await agent.post('/api/auth/login').send({ username: 'dr.mehta', password: 'wrong-password-123' });
  const b = await agent.post('/api/auth/login').send({ username: 'no.such.user', password: 'whatever-123' });
  assert.equal(a.status, 401);
  assert.equal(b.status, 401);
  assert.deepEqual(a.body, b.body);
  assert.equal(await metricValue(metrics, 'auth_login_failures_total', { reason: 'bad_credentials' }), 2);
});

test('malformed login body is rejected with 400', async () => {
  const { agent } = await buildApp();
  const res = await agent.post('/api/auth/login').send({ username: 'dr.mehta', password: 'x', role: 'admin' });
  assert.equal(res.status, 400);
});

test('account locks after repeated failures, even for the right password', async () => {
  const { agent, metrics, auditEvents } = await buildApp({ MAX_FAILED_LOGINS: '3' });
  for (let i = 0; i < 3; i += 1) {
    await agent.post('/api/auth/login').send({ username: 'nurse.priya', password: `bad-${i}-xxxxxxxx` });
  }
  const res = await agent.post('/api/auth/login').send({ username: 'nurse.priya', password: PASSWORDS.nurse });
  assert.equal(res.status, 401);
  assert.equal(await metricValue(metrics, 'auth_account_lockouts_total', {}), 1);
  assert.ok(auditEvents.some((e) => e.action === 'account_locked' && e.actor === 'nurse.priya'));
});

test('per-IP login rate limit returns 429', async () => {
  const { agent, metrics } = await buildApp({ LOGIN_RATE_LIMIT: '2' });
  for (let i = 0; i < 2; i += 1) await agent.post('/api/auth/login').send({ username: 'x', password: 'y' });
  const res = await agent.post('/api/auth/login').send({ username: 'x', password: 'y' });
  assert.equal(res.status, 429);
  assert.equal(await metricValue(metrics, 'auth_login_failures_total', { reason: 'rate_limited' }), 1);
});

test('requests without a token are rejected and counted', async () => {
  const { agent, metrics, auditEvents } = await buildApp();
  const res = await agent.get('/api/patients');
  assert.equal(res.status, 401);
  assert.equal(await metricValue(metrics, 'auth_unauthorized_requests_total', { reason: 'missing_token' }), 1);
  assert.ok(auditEvents.some((e) => e.action === 'access_denied'));
});

test('forged, alg:none and expired tokens are rejected', async () => {
  const { agent, config } = await buildApp();
  const forged = jwt.sign({ role: 'doctor' }, 'attacker-secret-attacker-secret-1234', {
    subject: 'dr.mehta', issuer: 'medsecure', audience: 'medsecure-api',
  });
  const header = Buffer.from(JSON.stringify({ alg: 'none', typ: 'JWT' })).toString('base64url');
  const body = Buffer.from(JSON.stringify({ sub: 'dr.mehta', role: 'doctor', iss: 'medsecure', aud: 'medsecure-api' })).toString('base64url');
  const none = `${header}.${body}.x`;
  const expired = jwt.sign({ role: 'doctor', exp: Math.floor(Date.now() / 1000) - 60 }, config.jwtSecret, {
    subject: 'dr.mehta', issuer: 'medsecure', audience: 'medsecure-api',
  });
  const escalated = jwt.sign({ role: 'doctor' }, config.jwtSecret, {
    subject: 'desk.ravi', issuer: 'medsecure', audience: 'medsecure-api', expiresIn: 60,
  });
  for (const t of [forged, none, expired, escalated]) {
    const res = await agent.get('/api/patients').set('Authorization', `Bearer ${t}`);
    assert.equal(res.status, 401);
  }
});

test('logout revokes the token', async () => {
  const { agent } = await buildApp();
  const token = await tokenFor(agent, 'doctor');
  assert.equal((await agent.get('/api/auth/me').set('Authorization', `Bearer ${token}`)).status, 200);
  assert.equal((await agent.post('/api/auth/logout').set('Authorization', `Bearer ${token}`)).status, 204);
  assert.equal((await agent.get('/api/auth/me').set('Authorization', `Bearer ${token}`)).status, 401);
});
