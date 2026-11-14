'use strict';

const crypto = require('node:crypto');
const request = require('supertest');
const { loadConfig } = require('../src/config');
const { createApp } = require('../src/app');

// Test-only secrets, generated fresh for every run (nothing hardcoded).
const PASSWORDS = {
  doctor: crypto.randomBytes(12).toString('hex'),
  nurse: crypto.randomBytes(12).toString('hex'),
  receptionist: crypto.randomBytes(12).toString('hex'),
};

function testEnv(overrides = {}) {
  return {
    NODE_ENV: 'test',
    JWT_SECRET: crypto.randomBytes(32).toString('hex'),
    PHI_ENCRYPTION_KEY: crypto.randomBytes(32).toString('base64'),
    DOCTOR_PASSWORD: PASSWORDS.doctor,
    NURSE_PASSWORD: PASSWORDS.nurse,
    RECEPTIONIST_PASSWORD: PASSWORDS.receptionist,
    LOGIN_RATE_LIMIT: '100',
    ...overrides,
  };
}

async function buildApp(envOverrides = {}) {
  const config = loadConfig(testEnv(envOverrides));
  const auditEvents = [];
  const built = await createApp({ config, log: () => {}, audit: (e) => auditEvents.push(e) });
  return { ...built, config, auditEvents, agent: request(built.app) };
}

const USERNAMES = { doctor: 'dr.mehta', nurse: 'nurse.priya', receptionist: 'desk.ravi' };

async function tokenFor(agent, role) {
  const res = await agent.post('/api/auth/login').send({ username: USERNAMES[role], password: PASSWORDS[role] });
  if (res.status !== 200) throw new Error(`login failed for ${role}: ${res.status}`);
  return res.body.token;
}

const VALID_PATIENT = Object.freeze({
  firstName: 'Rohan',
  lastName: 'Verma',
  dateOfBirth: '1990-05-17',
  gender: 'male',
  bloodGroup: 'A-',
  phone: '+919811112222',
  nationalId: '499912345678',
  allergies: ['Aspirin'],
});

module.exports = { buildApp, testEnv, tokenFor, PASSWORDS, USERNAMES, VALID_PATIENT };
