'use strict';

// Authentication (JWT) and role-based access control.
//
// * Passwords are never stored in plaintext: they arrive via environment
//   variables (Kubernetes Secret) and are immediately hashed with scrypt.
// * Login compares hashes in constant time, and runs a dummy hash for unknown
//   usernames, so response timing does not reveal which usernames exist.
// * After MAX_FAILED_LOGINS failures an account is locked for LOCKOUT_SECONDS.
// * Tokens are short-lived (15 min), HS256 only (rejects "alg: none" and
//   algorithm-confusion attacks), with fixed issuer and audience, and can be
//   revoked on logout.

const crypto = require('node:crypto');
const { promisify } = require('node:util');
const jwt = require('jsonwebtoken');

const scrypt = promisify(crypto.scrypt);
const ISSUER = 'medsecure';
const AUDIENCE = 'medsecure-api';
const KEY_LEN = 64;

const USERS = Object.freeze([
  { username: 'dr.mehta', role: 'doctor', displayName: 'Dr. Anika Mehta' },
  { username: 'nurse.priya', role: 'nurse', displayName: 'Nurse Priya Nair' },
  { username: 'desk.ravi', role: 'receptionist', displayName: 'Ravi Kumar (Front desk)' },
]);

async function hashPassword(password, salt = crypto.randomBytes(16)) {
  return { salt, hash: await scrypt(password, salt, KEY_LEN) };
}

async function createAuthService({ config, metrics, audit, now = () => Date.now() }) {
  const accounts = new Map();
  for (const u of USERS) {
    accounts.set(u.username, { ...u, ...(await hashPassword(config.passwords[u.role])) });
  }
  const dummy = await hashPassword(crypto.randomBytes(32).toString('hex'));

  const failures = new Map(); // username -> { count, lockedUntil }
  const revoked = new Map(); // jti -> expiry (ms)

  function isLocked(username) {
    const f = failures.get(username);
    return Boolean(f && f.lockedUntil && f.lockedUntil > now());
  }

  function recordFailure(username) {
    const f = failures.get(username) || { count: 0, lockedUntil: 0 };
    if (f.lockedUntil && f.lockedUntil <= now()) {
      f.count = 0;
      f.lockedUntil = 0;
    }
    f.count += 1;
    if (f.count >= config.maxFailedLogins && !f.lockedUntil) {
      f.lockedUntil = now() + config.lockoutSeconds * 1000;
      metrics.lockouts.inc();
      audit({ action: 'account_locked', actor: username, outcome: 'locked' });
    }
    failures.set(username, f);
  }

  async function verifyPassword(account, password) {
    const target = account || dummy;
    const { hash } = await hashPassword(password, target.salt);
    return crypto.timingSafeEqual(hash, target.hash) && Boolean(account);
  }

  // Returns { token, user } on success or { error, reason } on failure.
  async function login(username, password, ip) {
    const account = accounts.get(username);

    if (account && isLocked(username)) {
      await verifyPassword(null, password); // keep timing uniform
      metrics.loginAttempts.inc({ result: 'failure' });
      metrics.loginFailures.inc({ reason: 'locked' });
      audit({ action: 'login', actor: username, outcome: 'denied_locked', ip });
      return { error: true, reason: 'locked' };
    }

    const ok = await verifyPassword(account, password);
    if (!ok) {
      if (account) recordFailure(username);
      metrics.loginAttempts.inc({ result: 'failure' });
      metrics.loginFailures.inc({ reason: 'bad_credentials' });
      audit({ action: 'login', actor: username, outcome: 'failure', ip });
      return { error: true, reason: 'bad_credentials' };
    }

    failures.delete(username);
    const jti = crypto.randomUUID();
    const token = jwt.sign({ role: account.role, name: account.displayName }, config.jwtSecret, {
      algorithm: 'HS256',
      subject: account.username,
      issuer: ISSUER,
      audience: AUDIENCE,
      expiresIn: config.tokenTtlSeconds,
      jwtid: jti,
    });
    metrics.loginAttempts.inc({ result: 'success' });
    audit({ action: 'login', actor: username, role: account.role, outcome: 'success', ip });
    return {
      token,
      expiresIn: config.tokenTtlSeconds,
      user: { username: account.username, role: account.role, displayName: account.displayName },
    };
  }

  function revoke(jti, expSeconds) {
    revoked.set(jti, expSeconds * 1000);
    for (const [id, exp] of revoked) if (exp <= now()) revoked.delete(id);
  }

  function deny(req, res, status, reason) {
    metrics.unauthorized.inc({ reason });
    audit({
      action: 'access_denied',
      reason,
      actor: req.user ? req.user.username : 'anonymous',
      method: req.method,
      path: req.baseUrl + req.path,
      ip: req.ip,
      requestId: req.id,
    });
    res.status(status).json({ error: status === 401 ? 'Authentication required' : 'Forbidden' });
  }

  // Middleware: requires a valid Bearer token.
  function authenticate(req, res, next) {
    const header = req.get('authorization') || '';
    const match = /^Bearer ([\w-]+\.[\w-]+\.[\w-]+)$/.exec(header);
    if (!match) return deny(req, res, 401, 'missing_token');

    let payload;
    try {
      payload = jwt.verify(match[1], config.jwtSecret, {
        algorithms: ['HS256'],
        issuer: ISSUER,
        audience: AUDIENCE,
        clockTolerance: 5,
      });
    } catch (err) {
      return deny(req, res, 401, err.name === 'TokenExpiredError' ? 'expired_token' : 'invalid_token');
    }

    const account = accounts.get(payload.sub);
    if (!account || account.role !== payload.role || revoked.has(payload.jti)) {
      return deny(req, res, 401, 'invalid_token');
    }
    req.user = { username: account.username, role: account.role, displayName: account.displayName };
    req.token = { jti: payload.jti, exp: payload.exp };
    return next();
  }

  // Middleware factory: allows only the given roles.
  function authorize(...roles) {
    return (req, res, next) => (roles.includes(req.user.role) ? next() : deny(req, res, 403, 'forbidden_role'));
  }

  return { login, authenticate, authorize, revoke, isLocked };
}

module.exports = { createAuthService, USERS, ISSUER, AUDIENCE };
