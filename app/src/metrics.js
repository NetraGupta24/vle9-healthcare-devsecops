'use strict';

// Prometheus metrics. Served on a SEPARATE port (METRICS_PORT, default 9464)
// that is not exposed by the public Service, so attackers cannot read
// operational data; only Prometheus (allowed by a NetworkPolicy) can scrape it.
// Labels never contain PHI, usernames or patient ids.

const client = require('prom-client');

function createMetrics() {
  const register = new client.Registry();
  register.setDefaultLabels({ app: 'medsecure-patient-api' });
  client.collectDefaultMetrics({ register });

  const httpRequests = new client.Counter({
    name: 'http_requests_total',
    help: 'HTTP requests handled, by method, route template and status code',
    labelNames: ['method', 'route', 'status_code'],
    registers: [register],
  });

  const httpDuration = new client.Histogram({
    name: 'http_request_duration_seconds',
    help: 'HTTP request latency in seconds',
    labelNames: ['method', 'route', 'status_code'],
    buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5],
    registers: [register],
  });

  const loginAttempts = new client.Counter({
    name: 'auth_login_attempts_total',
    help: 'Login attempts by result (success|failure)',
    labelNames: ['result'],
    registers: [register],
  });

  const loginFailures = new client.Counter({
    name: 'auth_login_failures_total',
    help: 'Failed logins by reason (bad_credentials|locked|rate_limited|invalid_request)',
    labelNames: ['reason'],
    registers: [register],
  });

  const lockouts = new client.Counter({
    name: 'auth_account_lockouts_total',
    help: 'Accounts locked after too many failed logins',
    registers: [register],
  });

  const unauthorized = new client.Counter({
    name: 'auth_unauthorized_requests_total',
    help: 'Requests rejected by authentication/authorisation (missing_token|invalid_token|expired_token|forbidden_role)',
    labelNames: ['reason'],
    registers: [register],
  });

  const phiAccess = new client.Counter({
    name: 'phi_records_accessed_total',
    help: 'Patient records read or written, by action and role (for bulk-access / exfiltration alerts)',
    labelNames: ['action', 'role'],
    registers: [register],
  });

  // Pre-create the label sets the alerts use, so their series exist (as 0)
  // from the first scrape and increase() works on the very first event.
  for (const r of ['success', 'failure']) loginAttempts.inc({ result: r }, 0);
  for (const r of ['bad_credentials', 'locked', 'rate_limited', 'invalid_request']) loginFailures.inc({ reason: r }, 0);
  for (const r of ['missing_token', 'invalid_token', 'expired_token', 'forbidden_role']) unauthorized.inc({ reason: r }, 0);
  // Without this, a burst of reads right after a pod starts creates the series
  // already at e.g. 80, increase() sees no change, and PHIBulkAccess never fires
  // (found in the first AWS run of scripts/demo/trigger-alerts.sh).
  for (const action of ['list', 'read', 'create', 'update_clinical']) {
    for (const role of ['doctor', 'nurse', 'receptionist']) phiAccess.inc({ action, role }, 0);
  }

  return { register, httpRequests, httpDuration, loginAttempts, loginFailures, lockouts, unauthorized, phiAccess };
}

module.exports = { createMetrics };
