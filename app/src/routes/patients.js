'use strict';

// Patient record endpoints.
//
// Access matrix ("minimum necessary" rule):
//                       list  read   create  update clinical  sees national id  sees diagnosis/notes
//   doctor               yes  yes    yes     yes              full              yes
//   nurse                yes  yes    no      no               masked            yes
//   receptionist         yes  yes    yes     no               masked            no

const express = require('express');
const { newPatientSchema, clinicalUpdateSchema, UUID, formatIssues } = require('../validation');

function ageFrom(dateOfBirth, today = new Date()) {
  const dob = new Date(`${dateOfBirth}T00:00:00Z`);
  let age = today.getUTCFullYear() - dob.getUTCFullYear();
  const m = today.getUTCMonth() - dob.getUTCMonth();
  if (m < 0 || (m === 0 && today.getUTCDate() < dob.getUTCDate())) age -= 1;
  return age;
}

function maskNationalId(id) {
  return `XXXX-XXXX-${String(id).slice(-4)}`;
}

function summaryView(p) {
  return {
    id: p.id,
    name: `${p.firstName} ${p.lastName}`,
    age: ageFrom(p.dateOfBirth),
    gender: p.gender,
    bloodGroup: p.bloodGroup,
  };
}

function detailView(p, role) {
  const view = {
    id: p.id,
    firstName: p.firstName,
    lastName: p.lastName,
    dateOfBirth: p.dateOfBirth,
    age: ageFrom(p.dateOfBirth),
    gender: p.gender,
    bloodGroup: p.bloodGroup,
    phone: p.phone,
    allergies: p.allergies,
    nationalId: role === 'doctor' ? p.nationalId : maskNationalId(p.nationalId),
    createdAt: p.createdAt,
    updatedAt: p.updatedAt,
  };
  if (role === 'doctor' || role === 'nurse') {
    view.diagnosis = p.diagnosis ?? null;
    view.notes = p.notes ?? null;
  }
  return view;
}

function createPatientsRouter({ auth, store, audit, metrics }) {
  const router = express.Router();
  router.use(auth.authenticate);

  function logAccess(req, action, patientId, outcome = 'success') {
    metrics.phiAccess.inc({ action, role: req.user.role });
    audit({
      action,
      actor: req.user.username,
      role: req.user.role,
      patientId,
      outcome,
      ip: req.ip,
      requestId: req.id,
    });
  }

  function validId(req, res) {
    if (!UUID.test(req.params.id)) {
      res.status(400).json({ error: 'Invalid patient id' });
      return false;
    }
    return true;
  }

  router.get('/', (req, res) => {
    const patients = store.list().map(summaryView);
    patients.sort((a, b) => a.name.localeCompare(b.name));
    logAccess(req, 'list', `count=${patients.length}`);
    res.json({ patients });
  });

  router.get('/:id', (req, res) => {
    if (!validId(req, res)) return;
    const patient = store.get(req.params.id);
    if (!patient) return res.status(404).json({ error: 'Patient not found' });
    logAccess(req, 'read', patient.id);
    return res.json({ patient: detailView(patient, req.user.role) });
  });

  router.post('/', auth.authorize('doctor', 'receptionist'), (req, res) => {
    const parsed = newPatientSchema.safeParse(req.body);
    if (!parsed.success) {
      return res.status(400).json({ error: 'Validation failed', details: formatIssues(parsed.error) });
    }
    const data = { ...parsed.data };
    // Only a doctor may record clinical information.
    if (req.user.role !== 'doctor' && (data.diagnosis !== undefined || data.notes !== undefined)) {
      return auth.authorize('doctor')(req, res);
    }
    const patient = store.create(data, req.user.username);
    logAccess(req, 'create', patient.id);
    return res.status(201).location(`/api/patients/${patient.id}`).json({ patient: detailView(patient, req.user.role) });
  });

  router.patch('/:id/clinical', auth.authorize('doctor'), (req, res) => {
    if (!validId(req, res)) return;
    const parsed = clinicalUpdateSchema.safeParse(req.body);
    if (!parsed.success) {
      return res.status(400).json({ error: 'Validation failed', details: formatIssues(parsed.error) });
    }
    const patient = store.update(req.params.id, parsed.data);
    if (!patient) return res.status(404).json({ error: 'Patient not found' });
    logAccess(req, 'update_clinical', patient.id);
    return res.json({ patient: detailView(patient, req.user.role) });
  });

  return router;
}

module.exports = { createPatientsRouter, maskNationalId, ageFrom };
