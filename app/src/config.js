'use strict';

// All secrets come from environment variables (injected from a Kubernetes
// Secret in production). There are deliberately NO default values for them:
// if a secret is missing the app refuses to start instead of silently running
// with a weak or hardcoded value.

const MIN_JWT_SECRET_LENGTH = 32;
const MIN_PASSWORD_LENGTH = 12;

class ConfigError extends Error {}

function readRequired(env, name) {
  const value = env[name];
  if (typeof value !== 'string' || value.trim() === '') {
    throw new ConfigError(`Missing required environment variable ${name}`);
  }
  return value.trim();
}

function readInt(env, name, fallback) {
  if (env[name] === undefined || env[name] === '') return fallback;
  const n = Number.parseInt(env[name], 10);
  if (!Number.isInteger(n) || n <= 0 || n > 65535) {
    throw new ConfigError(`${name} must be a positive integer`);
  }
  return n;
}

function loadConfig(env = process.env) {
  const jwtSecret = readRequired(env, 'JWT_SECRET');
  if (jwtSecret.length < MIN_JWT_SECRET_LENGTH) {
    throw new ConfigError(`JWT_SECRET must be at least ${MIN_JWT_SECRET_LENGTH} characters`);
  }

  // 32 random bytes, base64 encoded (openssl rand -base64 32) => AES-256 key.
  const phiKey = Buffer.from(readRequired(env, 'PHI_ENCRYPTION_KEY'), 'base64');
  if (phiKey.length !== 32) {
    throw new ConfigError('PHI_ENCRYPTION_KEY must be 32 bytes, base64 encoded (openssl rand -base64 32)');
  }

  const passwords = {
    doctor: readRequired(env, 'DOCTOR_PASSWORD'),
    nurse: readRequired(env, 'NURSE_PASSWORD'),
    receptionist: readRequired(env, 'RECEPTIONIST_PASSWORD'),
  };
  for (const [role, pw] of Object.entries(passwords)) {
    if (pw.length < MIN_PASSWORD_LENGTH) {
      throw new ConfigError(`${role.toUpperCase()}_PASSWORD must be at least ${MIN_PASSWORD_LENGTH} characters`);
    }
  }

  return Object.freeze({
    env: env.NODE_ENV || 'production',
    port: readInt(env, 'PORT', 3000),
    metricsPort: readInt(env, 'METRICS_PORT', 9464),
    jwtSecret,
    tokenTtlSeconds: readInt(env, 'SESSION_TTL_SECONDS', 900),
    phiKey,
    passwords,
    seedDemoData: (env.SEED_DEMO_DATA || 'true') === 'true',
    loginRateLimit: readInt(env, 'LOGIN_RATE_LIMIT', 20),
    apiRateLimit: readInt(env, 'API_RATE_LIMIT', 300),
    maxFailedLogins: readInt(env, 'MAX_FAILED_LOGINS', 5),
    lockoutSeconds: readInt(env, 'LOCKOUT_SECONDS', 900),
  });
}

module.exports = { loadConfig, ConfigError };
