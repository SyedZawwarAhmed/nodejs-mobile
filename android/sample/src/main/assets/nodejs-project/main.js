'use strict';
/**
 * main.js — Sample Node.js entry point running inside Android
 *
 * This file is bundled in the APK assets and started by NodejsRuntime.start()
 */

const bridge = require('@nodejs-mobile/bridge');
const http   = require('http');

console.log(`Node.js ${process.version} running on Android!`);

// ── Echo server: respond to ping messages ────────────────────────────────────
bridge.on('ping', (msg) => {
  console.log(`[Node] received ping: ${msg}`);
  bridge.send('pong', JSON.stringify({
    echo: msg,
    nodeVersion: process.version,
    platform: process.platform,
    timestamp: Date.now(),
  }));
});

// ── HTTP server on a random port ─────────────────────────────────────────────
const server = http.createServer((req, res) => {
  if (req.url === '/status') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      status: 'ok',
      node: process.version,
      uptime: process.uptime(),
    }));
  } else {
    res.writeHead(404);
    res.end('Not found');
  }
});

server.listen(0, '127.0.0.1', () => {
  const port = server.address().port;
  console.log(`[Node] HTTP server listening on port ${port}`);
  // Tell Android the port so it can make HTTP calls
  bridge.send('http-port', String(port));
});
