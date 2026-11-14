'use strict';

const crypto = require('node:crypto');
const path = require('node:path');
const express = require('express');
const helmet = require('helmet');
const { rateLimit } = require('express-rate-limit');

const { createMetrics } = require('./metrics');
const { createAuditLogger } = require('./audit');
const { createAuthService } = require('./auth');
const { createPhiCipher } = require('./phiCrypto');
const { createPatientStore, seedDemoPatients } = require('./store');
const { createAuthRouter } = require('./routes/auth');
const { createPatientsRouter } = require('./routes/patients');

const jsonLog = (obj) => process.stdout.write(`${JSON.stringify(obj)}\n`);

// Route *template* (e.g. /api/patients/:id), never the raw URL, so metric
// labels stay low-cardinality and never contain patient ids.
function routeLabel(req, res) {
  if (req.route) return `${req.baseUrl}${req.route.path}`;
  if (res.statusCode === 404) return 'unmatched';
  return req.originalUrl.startsWith('/api') ? req.baseUrl || '/api' : 'static';
}

async function createApp({
  config,
  metrics = createMetrics(),
  audit = createAuditLogger(),
  log = jsonLog,
  store,
} = {}) {
  if (!config) throw new Error('config is required');
  const patientStore = store || createPatientStore(createPhiCipher(config.phiKey));
  if (!store && config.seedDemoData) seedDemoPatients(patientStore);

  const auth = await createAuthService({ config, metrics, audit });
  const app = express();
  app.disable('x-powered-by');
  app.set('trust proxy', false);

  // Request id, metrics and access log (method, route template, status only:
  // no query strings, bodies or headers, which could contain PHI or tokens).
  app.use((req, res, next) => {
    req.id = crypto.randomUUID();
    res.set('X-Request-Id', req.id);
    const started = process.hrtime.bigint();
    res.on('finish', () => {
      const labels = { method: req.method, route: routeLabel(req, res), status_code: String(res.statusCode) };
      const seconds = Number(process.hrtime.bigint() - started) / 1e9;
      metrics.httpRequests.inc(labels);
      metrics.httpDuration.observe(labels, seconds);
      log({ type: 'access', ts: new Date().toISOString(), ...labels, ms: Math.round(seconds * 1000), requestId: req.id });
    });
    next();
  });

  // Security headers (OWASP Secure Headers).
  app.use(
    helmet({
      contentSecurityPolicy: {
        useDefaults: false,
        directives: {
          defaultSrc: ["'self'"],
          scriptSrc: ["'self'"],
          styleSrc: ["'self'"],
          imgSrc: ["'self'", 'data:'],
          connectSrc: ["'self'"],
          fontSrc: ["'self'"],
          objectSrc: ["'none'"],
          baseUri: ["'self'"],
          formAction: ["'self'"],
          frameAncestors: ["'none'"],
        },
      },
      crossOriginEmbedderPolicy: true,
      crossOriginOpenerPolicy: { policy: 'same-origin' },
      crossOriginResourcePolicy: { policy: 'same-origin' },
      referrerPolicy: { policy: 'no-referrer' },
      strictTransportSecurity: { maxAge: 31536000, includeSubDomains: true },
    }),
  );
  app.use((req, res, next) => {
    // PHI must never be stored by browsers or proxies.
    res.set('Cache-Control', 'no-store');
    res.set('Pragma', 'no-cache');
    res.set('Permissions-Policy', 'camera=(), microphone=(), geolocation=(), payment=(), usb=()');
    next();
  });

  app.get('/healthz', (req, res) => res.json({ status: 'ok' }));
  app.get('/readyz', (req, res) => res.json({ status: 'ready', patients: patientStore.size() }));

  app.use(
    express.static(path.join(__dirname, '..', 'public'), {
      index: 'index.html',
      dotfiles: 'ignore',
      cacheControl: false,
      redirect: false,
    }),
  );

  const apiLimiter = rateLimit({
    windowMs: 60 * 1000,
    limit: config.apiRateLimit,
    standardHeaders: 'draft-8',
    legacyHeaders: false,
    message: { error: 'Too many requests' },
  });
  app.use('/api', apiLimiter, express.json({ limit: '10kb', strict: true, type: 'application/json' }));
  app.use('/api/auth', createAuthRouter({ auth, metrics, config }));
  app.use('/api/patients', createPatientsRouter({ auth, store: patientStore, audit, metrics }));

  app.use((req, res) => res.status(404).json({ error: 'Not found' }));

  // Central error handler: generic message to the client, details only in logs.
  // eslint-disable-next-line no-unused-vars
  app.use((err, req, res, next) => {
    if (err.type === 'entity.parse.failed') return res.status(400).json({ error: 'Malformed JSON' });
    if (err.type === 'entity.too.large') return res.status(413).json({ error: 'Request body too large' });
    log({ type: 'error', ts: new Date().toISOString(), requestId: req.id, message: err.message });
    return res.status(500).json({ error: 'Internal server error', requestId: req.id });
  });

  return { app, auth, store: patientStore, metrics };
}

module.exports = { createApp, routeLabel };
