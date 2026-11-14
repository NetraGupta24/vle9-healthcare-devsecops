'use strict';

const express = require('express');
const { rateLimit } = require('express-rate-limit');
const { loginSchema, formatIssues } = require('../validation');

function createAuthRouter({ auth, metrics, config }) {
  const router = express.Router();

  // Per-IP limit on login attempts (brute force / credential stuffing).
  const loginLimiter = rateLimit({
    windowMs: 15 * 60 * 1000,
    limit: config.loginRateLimit,
    standardHeaders: 'draft-8',
    legacyHeaders: false,
    handler: (req, res) => {
      metrics.loginAttempts.inc({ result: 'failure' });
      metrics.loginFailures.inc({ reason: 'rate_limited' });
      res.status(429).json({ error: 'Too many login attempts. Try again later.' });
    },
  });

  router.post('/login', loginLimiter, async (req, res, next) => {
    try {
      const parsed = loginSchema.safeParse(req.body);
      if (!parsed.success) {
        metrics.loginAttempts.inc({ result: 'failure' });
        metrics.loginFailures.inc({ reason: 'invalid_request' });
        return res.status(400).json({ error: 'Invalid request', details: formatIssues(parsed.error) });
      }
      const result = await auth.login(parsed.data.username, parsed.data.password, req.ip);
      if (result.error) {
        // Same message for unknown user, wrong password and locked account,
        // so the response does not help an attacker enumerate accounts.
        return res.status(401).json({ error: 'Invalid username or password' });
      }
      return res.json(result);
    } catch (err) {
      return next(err);
    }
  });

  router.get('/me', auth.authenticate, (req, res) => res.json({ user: req.user }));

  router.post('/logout', auth.authenticate, (req, res) => {
    auth.revoke(req.token.jti, req.token.exp);
    res.status(204).end();
  });

  return router;
}

module.exports = { createAuthRouter };
