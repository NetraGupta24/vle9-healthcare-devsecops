'use strict';

// Used by the Dockerfile HEALTHCHECK (the image has no curl/wget on purpose).
const http = require('node:http');

const port = Number.parseInt(process.env.PORT || '3000', 10);
const req = http.get({ host: '127.0.0.1', port, path: '/healthz', timeout: 3000 }, (res) => {
  process.exit(res.statusCode === 200 ? 0 : 1);
});
req.on('error', () => process.exit(1));
req.on('timeout', () => {
  req.destroy();
  process.exit(1);
});
