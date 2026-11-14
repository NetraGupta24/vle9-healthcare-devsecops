'use strict';

// In-memory patient store. Every PHI field is kept ONLY in encrypted form;
// the plaintext exists just for the duration of a request.
//
// The lab keeps the app stateless (no database) so it fits on one small EC2
// instance. In a real hospital system this would be an encrypted database
// (for example Amazon RDS with KMS encryption) - see docs/SECURITY-CONTROLS.md.

const crypto = require('node:crypto');

function createPatientStore(cipher) {
  const records = new Map();

  function create(phi, actor) {
    const id = crypto.randomUUID();
    const now = new Date().toISOString();
    records.set(id, {
      id,
      createdAt: now,
      updatedAt: now,
      createdBy: actor,
      phi: cipher.encrypt(phi, id),
    });
    return { id, createdAt: now, updatedAt: now, ...phi };
  }

  function get(id) {
    const rec = records.get(id);
    if (!rec) return null;
    return { id: rec.id, createdAt: rec.createdAt, updatedAt: rec.updatedAt, ...cipher.decrypt(rec.phi, rec.id) };
  }

  function list() {
    return [...records.values()].map((rec) => ({
      id: rec.id,
      createdAt: rec.createdAt,
      updatedAt: rec.updatedAt,
      ...cipher.decrypt(rec.phi, rec.id),
    }));
  }

  function update(id, changes) {
    const rec = records.get(id);
    if (!rec) return null;
    const merged = { ...cipher.decrypt(rec.phi, rec.id), ...changes };
    rec.phi = cipher.encrypt(merged, rec.id);
    rec.updatedAt = new Date().toISOString();
    return { id: rec.id, createdAt: rec.createdAt, updatedAt: rec.updatedAt, ...merged };
  }

  // Exposed for tests: shows exactly what is held in memory (ciphertext only).
  function rawRecord(id) {
    const rec = records.get(id);
    return rec ? { ...rec } : null;
  }

  return { create, get, list, update, rawRecord, size: () => records.size };
}

// Synthetic demo patients. Not real people; the national IDs are made up.
const DEMO_PATIENTS = [
  {
    firstName: 'Aarav', lastName: 'Sharma', dateOfBirth: '1984-03-12', gender: 'male', bloodGroup: 'B+',
    phone: '+919800000001', nationalId: '400011112222', allergies: ['Penicillin'],
    diagnosis: 'Type 2 diabetes mellitus', notes: 'HbA1c 7.2%. Continue metformin 500 mg BD.',
  },
  {
    firstName: 'Diya', lastName: 'Patel', dateOfBirth: '1992-11-02', gender: 'female', bloodGroup: 'O-',
    phone: '+919800000002', nationalId: '400033334444', allergies: [],
    diagnosis: 'Iron deficiency anaemia', notes: 'Ferritin low. Oral iron for 3 months, review CBC.',
  },
  {
    firstName: 'Kabir', lastName: 'Singh', dateOfBirth: '1958-07-25', gender: 'male', bloodGroup: 'A+',
    phone: '+919800000003', nationalId: '400055556666', allergies: ['Sulfonamides', 'Latex'],
    diagnosis: 'Hypertension, stage 2', notes: 'BP 158/96. Started amlodipine 5 mg OD.',
  },
  {
    firstName: 'Meera', lastName: 'Iyer', dateOfBirth: '2001-01-30', gender: 'female', bloodGroup: 'AB+',
    phone: '+919800000004', nationalId: '400077778888', allergies: ['Peanuts'],
    diagnosis: 'Mild persistent asthma', notes: 'Inhaled budesonide 200 mcg BD. Spacer technique reviewed.',
  },
];

function seedDemoPatients(store) {
  for (const p of DEMO_PATIENTS) store.create(p, 'seed');
}

module.exports = { createPatientStore, seedDemoPatients, DEMO_PATIENTS };
