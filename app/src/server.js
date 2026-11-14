'use strict';

const http = require('node:http');
const { loadConfig } = require('./config');
const { createMetrics } = require('./metrics');
const { createApp } = require('./app');

// Minimal, separate HTTP server that serves ONLY GET /metrics.
function createMetricsServer(register) {
  return http.createServer(async (req, res) => {
    if (req.method === 'GET' && req.url === '/metrics') {
      res.setHeader('Content-Type', register.contentType);
      res.end(await register.metrics());
      return;
    }
    res.statusCode = 404;
    res.end('Not found');
  });
}

async function main() {
  let config;
  try {
    config = loadConfig();
  } catch (err) {
    // Print the reason (never the value) and stop: fail closed.
    process.stderr.write(`${JSON.stringify({ level: 'fatal', message: err.message })}\n`);
    process.exit(1);
  }

  const metrics = createMetrics();
  const { app } = await createApp({ config, metrics });

  const server = app.listen(config.port, () => {
    process.stdout.write(`${JSON.stringify({ level: 'info', message: `MedSecure API listening on :${config.port}` })}\n`);
  });
  server.requestTimeout = 30_000;
  server.headersTimeout = 15_000;

  const metricsServer = createMetricsServer(metrics.register).listen(config.metricsPort, () => {
    process.stdout.write(`${JSON.stringify({ level: 'info', message: `Metrics on :${config.metricsPort}/metrics` })}\n`);
  });

  // Graceful shutdown: Kubernetes sends SIGTERM before killing the pod.
  const shutdown = (signal) => {
    process.stdout.write(`${JSON.stringify({ level: 'info', message: `${signal} received, shutting down` })}\n`);
    server.close(() => metricsServer.close(() => process.exit(0)));
    setTimeout(() => process.exit(0), 10_000).unref();
  };
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

if (require.main === module) {
  main().catch((err) => {
    process.stderr.write(`${JSON.stringify({ level: 'fatal', message: err.message })}\n`);
    process.exit(1);
  });
}

module.exports = { createMetricsServer };
