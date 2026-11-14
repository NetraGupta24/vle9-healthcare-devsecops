'use strict';

// Input validation (secure coding, Step 3 of the lab).
// Allow-lists, not block-lists: each field says exactly what it may contain.
// strictObject() rejects unknown fields, which stops "mass assignment"
// (for example a client sending {"role":"doctor"} or {"id":"..."}).

const { z } = require('zod');

// Letters (any language), spaces, dot, apostrophe, hyphen. No < > " & etc.
const NAME = z
  .string()
  .trim()
  .min(1)
  .max(50)
  .regex(/^\p{L}[\p{L} .'-]*$/u, 'may contain only letters, spaces and . \' -');

// Free text: printable characters only, no angle brackets (defence in depth
// against stored XSS; the UI also renders with textContent, never innerHTML).
const SAFE_TEXT = /^[^<>\p{Cc}]*$/u;

const BLOOD_GROUPS = ['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-', 'unknown'];

const dateOfBirth = z
  .string()
  .regex(/^\d{4}-\d{2}-\d{2}$/, 'must be YYYY-MM-DD')
  .refine((s) => {
    const d = new Date(`${s}T00:00:00Z`);
    return !Number.isNaN(d.getTime()) && d.toISOString().startsWith(s);
  }, 'is not a real date')
  .refine((s) => {
    const d = new Date(`${s}T00:00:00Z`);
    return d <= new Date() && d.getUTCFullYear() >= 1900;
  }, 'must be between 1900 and today');

const clinicalFields = {
  diagnosis: z.string().trim().max(500).regex(SAFE_TEXT, 'contains forbidden characters').optional(),
  notes: z.string().trim().max(2000).regex(SAFE_TEXT, 'contains forbidden characters').optional(),
};

const newPatientSchema = z.strictObject({
  firstName: NAME,
  lastName: NAME,
  dateOfBirth,
  gender: z.enum(['female', 'male', 'other', 'unknown']),
  bloodGroup: z.enum(BLOOD_GROUPS).default('unknown'),
  phone: z.string().trim().regex(/^\+?\d{10,15}$/, 'must be 10-15 digits, optional leading +'),
  nationalId: z.string().trim().regex(/^\d{12}$/, 'must be exactly 12 digits'),
  allergies: z
    .array(z.string().trim().min(1).max(50).regex(/^[\p{L}\p{N} ,.'()-]+$/u, 'contains forbidden characters'))
    .max(20)
    .default([]),
  ...clinicalFields,
});

const clinicalUpdateSchema = z
  .strictObject(clinicalFields)
  .refine((v) => v.diagnosis !== undefined || v.notes !== undefined, 'send diagnosis and/or notes');

const loginSchema = z.strictObject({
  username: z.string().trim().min(1).max(64).regex(/^[a-z0-9._-]+$/),
  password: z.string().min(1).max(128),
});

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

function formatIssues(error) {
  return error.issues.map((i) => ({ field: i.path.join('.') || '(body)', message: i.message }));
}

module.exports = { newPatientSchema, clinicalUpdateSchema, loginSchema, UUID, formatIssues };
