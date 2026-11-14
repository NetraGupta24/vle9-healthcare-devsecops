'use strict';

// Structured audit log (HIPAA 164.312(b) "audit controls"): who accessed which
// record, when, from where, and whether it was allowed. One JSON object per
// line on stdout, collected by `kubectl logs` / any log shipper.
// It records the patient id only - never names, diagnoses or other PHI.

function createAuditLogger(write = (line) => process.stdout.write(`${line}\n`)) {
  return function audit(event) {
    write(JSON.stringify({ type: 'audit', ts: new Date().toISOString(), ...event }));
  };
}

module.exports = { createAuditLogger };
