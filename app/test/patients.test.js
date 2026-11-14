'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { buildApp, tokenFor, VALID_PATIENT } = require('./helpers');
const { maskNationalId, ageFrom } = require('../src/routes/patients');

async function setup() {
  const ctx = await buildApp();
  ctx.tokens = {
    doctor: await tokenFor(ctx.agent, 'doctor'),
    nurse: await tokenFor(ctx.agent, 'nurse'),
    receptionist: await tokenFor(ctx.agent, 'receptionist'),
  };
  ctx.as = (role) => ({
    get: (url) => ctx.agent.get(url).set('Authorization', `Bearer ${ctx.tokens[role]}`),
    post: (url, body) => ctx.agent.post(url).set('Authorization', `Bearer ${ctx.tokens[role]}`).send(body),
    patch: (url, body) => ctx.agent.patch(url).set('Authorization', `Bearer ${ctx.tokens[role]}`).send(body),
  });
  const list = await ctx.as('doctor').get('/api/patients');
  ctx.firstId = list.body.patients[0].id;
  return ctx;
}

test('every role can list patients (summary only, no PHI identifiers)', async () => {
  const { as } = await setup();
  for (const role of ['doctor', 'nurse', 'receptionist']) {
    const res = await as(role).get('/api/patients');
    assert.equal(res.status, 200);
    assert.equal(res.body.patients.length, 4);
    assert.deepEqual(Object.keys(res.body.patients[0]).sort(), ['age', 'bloodGroup', 'gender', 'id', 'name']);
  }
});

test('doctor sees full record, nurse masked id, receptionist no clinical data', async () => {
  const { as, firstId } = await setup();
  const doctor = (await as('doctor').get(`/api/patients/${firstId}`)).body.patient;
  const nurse = (await as('nurse').get(`/api/patients/${firstId}`)).body.patient;
  const desk = (await as('receptionist').get(`/api/patients/${firstId}`)).body.patient;

  assert.match(doctor.nationalId, /^\d{12}$/);
  assert.ok('diagnosis' in doctor);
  assert.match(nurse.nationalId, /^XXXX-XXXX-\d{4}$/);
  assert.ok('diagnosis' in nurse);
  assert.match(desk.nationalId, /^XXXX-XXXX-\d{4}$/);
  assert.ok(!('diagnosis' in desk));
  assert.ok(!('notes' in desk));
});

test('reads are audit-logged with patient id but no PHI', async () => {
  const { as, firstId, auditEvents } = await setup();
  await as('nurse').get(`/api/patients/${firstId}`);
  const ev = auditEvents.find((e) => e.action === 'read' && e.patientId === firstId);
  assert.ok(ev);
  assert.equal(ev.actor, 'nurse.priya');
  assert.ok(!JSON.stringify(ev).match(/diagnosis|nationalId|\+91/));
});

test('receptionist can register a patient; nurse cannot', async () => {
  const { as } = await setup();
  const created = await as('receptionist').post('/api/patients', VALID_PATIENT);
  assert.equal(created.status, 201);
  assert.match(created.headers.location, /^\/api\/patients\/[0-9a-f-]{36}$/);
  const denied = await as('nurse').post('/api/patients', VALID_PATIENT);
  assert.equal(denied.status, 403);
});

test('receptionist cannot record clinical data when registering', async () => {
  const { as } = await setup();
  const res = await as('receptionist').post('/api/patients', { ...VALID_PATIENT, diagnosis: 'Flu' });
  assert.equal(res.status, 403);
});

const BAD_INPUTS = {
  'script tag in name': { firstName: '<script>alert(1)</script>' },
  'SQL injection in name': { lastName: "x' OR '1'='1" },
  'invalid phone': { phone: '12-34' },
  'national id with letters': { nationalId: '4000abcd2222' },
  'future date of birth': { dateOfBirth: '2999-01-01' },
  'impossible date': { dateOfBirth: '2020-02-31' },
  'unknown gender': { gender: 'robot' },
  'mass assignment (extra field)': { role: 'doctor' },
  'html in allergy': { allergies: ['<img src=x onerror=alert(1)>'] },
};

for (const [name, patch] of Object.entries(BAD_INPUTS)) {
  test(`input validation rejects ${name}`, async () => {
    const { as } = await setup();
    const res = await as('doctor').post('/api/patients', { ...VALID_PATIENT, ...patch });
    assert.equal(res.status, 400);
    assert.equal(res.body.error, 'Validation failed');
  });
}

test('only doctors can update clinical notes', async () => {
  const { as, firstId } = await setup();
  const ok = await as('doctor').patch(`/api/patients/${firstId}/clinical`, { diagnosis: 'Updated diagnosis' });
  assert.equal(ok.status, 200);
  assert.equal(ok.body.patient.diagnosis, 'Updated diagnosis');
  assert.equal((await as('nurse').patch(`/api/patients/${firstId}/clinical`, { notes: 'x' })).status, 403);
  assert.equal((await as('doctor').patch(`/api/patients/${firstId}/clinical`, {})).status, 400);
  assert.equal((await as('doctor').patch(`/api/patients/${firstId}/clinical`, { notes: '<b>x</b>' })).status, 400);
});

test('invalid and unknown ids', async () => {
  const { as } = await setup();
  assert.equal((await as('doctor').get('/api/patients/../../etc/passwd')).status, 404);
  assert.equal((await as('doctor').get('/api/patients/not-a-uuid')).status, 400);
  assert.equal((await as('doctor').get('/api/patients/7d444840-9dc0-41c1-a6a5-6f9c1b3d8a11')).status, 404);
});

test('helpers', () => {
  assert.equal(maskNationalId('400011112222'), 'XXXX-XXXX-2222');
  assert.equal(ageFrom('2000-06-15', new Date('2026-06-14T00:00:00Z')), 25);
  assert.equal(ageFrom('2000-06-15', new Date('2026-06-15T00:00:00Z')), 26);
});
