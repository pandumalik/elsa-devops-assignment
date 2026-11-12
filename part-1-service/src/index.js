'use strict';

const crypto = require('node:crypto');
const os = require('node:os');
const express = require('express');
const client = require('prom-client');

const PORT = Number(process.env.PORT || 3000);
const CPU_WORK_MS = Number(process.env.CPU_WORK_MS || 100);

const register = new client.Registry();
client.collectDefaultMetrics({ register, prefix: 'quote_api_' });

const httpRequestsTotal = new client.Counter({
  name: 'quote_api_http_requests_total',
  help: 'Total number of HTTP requests processed by the quote-api service',
  labelNames: ['method', 'route', 'status_code'],
  registers: [register],
});

const httpRequestDurationSeconds = new client.Histogram({
  name: 'quote_api_http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'route', 'status_code'],
  buckets: [0.01, 0.05, 0.1, 0.15, 0.25, 0.4, 0.6, 1.0, 2.5],
  registers: [register],
});

const cpuWorkDurationSeconds = new client.Summary({
  name: 'quote_api_cpu_work_duration_seconds',
  help: 'Actual CPU work duration spent per quote generation in seconds',
  percentiles: [0.5, 0.9, 0.99],
  registers: [register],
});

const QUOTES = [
  { author: 'Grace Hopper', quote: 'The most dangerous phrase in the language is: We have always done it this way.' },
  { author: 'Linus Torvalds', quote: 'Talk is cheap. Show me the code.' },
  { author: 'Kelsey Hightower', quote: 'No code is the best way to write secure and reliable applications.' },
  { author: 'Margaret Hamilton', quote: 'There was no choice but to be pioneers.' },
  { author: 'Werner Vogels', quote: 'Everything fails, all the time. Plan for failure.' },
  { author: 'Charity Majors', quote: 'Observability is about being able to ask arbitrary questions about your system.' },
  { author: 'Gene Kim', quote: 'Improving daily work is even more important than doing daily work.' },
  { author: 'Brendan Gregg', quote: 'Do not guess. Measure.' },
];

/**
 * Burns ~targetMs of real CPU time in 10ms slices, yielding via setImmediate
 * between slices so /healthz, /readyz, and /metrics probes are never starved
 * under heavy concurrent load.
 */
async function simulateCpuWork(targetMs) {
  const sliceMs = 10;
  let accumulatedMs = 0;
  let seed = Buffer.from('elsa-devops-quote-seed');

  while (accumulatedMs < targetMs) {
    const remaining = Math.min(sliceMs, targetMs - accumulatedMs);
    const sliceStart = process.hrtime.bigint();
    while (Number(process.hrtime.bigint() - sliceStart) / 1e6 < remaining) {
      seed = crypto.pbkdf2Sync(seed, 'salt', 500, 32, 'sha256');
    }
    accumulatedMs += Number(process.hrtime.bigint() - sliceStart) / 1e6;
    if (accumulatedMs < targetMs) {
      await new Promise((resolve) => setImmediate(resolve));
    }
  }
  return accumulatedMs;
}

function createApp() {
  const app = express();
  app.disable('x-powered-by');
  let isReady = true;

  app.use((req, res, next) => {
    const endTimer = httpRequestDurationSeconds.startTimer();
    res.on('finish', () => {
      // Only label with known route templates; unmatched paths (404 scans) share
      // one label value so they cannot blow up Prometheus series cardinality.
      const route = req.route ? `${req.baseUrl}${req.route.path}` : 'unmatched';
      const labels = {
        method: req.method,
        route,
        status_code: String(res.statusCode),
      };
      httpRequestsTotal.inc(labels);
      endTimer(labels);
    });
    next();
  });

  app.get('/healthz', (_req, res) => {
    res.status(200).json({ status: 'ok', hostname: os.hostname() });
  });

  app.get('/readyz', (_req, res) => {
    if (!isReady) {
      return res.status(503).json({ status: 'not_ready' });
    }
    return res.status(200).json({ status: 'ready', hostname: os.hostname() });
  });

  app.get('/metrics', async (_req, res) => {
    res.set('Content-Type', register.contentType);
    res.status(200).end(await register.metrics());
  });

  app.get('/api/quote', async (_req, res) => {
    const actualCpuMs = await simulateCpuWork(CPU_WORK_MS);
    cpuWorkDurationSeconds.observe(actualCpuMs / 1000);
    const item = QUOTES[crypto.randomInt(0, QUOTES.length)];
    res.status(200).json({
      quote: item.quote,
      author: item.author,
      cpuWorkMs: Math.round(actualCpuMs * 100) / 100,
      pod: os.hostname(),
      timestamp: new Date().toISOString(),
    });
  });

  app.setReady = (state) => {
    isReady = Boolean(state);
  };

  return app;
}

if (require.main === module) {
  const app = createApp();
  const server = app.listen(PORT, '0.0.0.0', () => {
    console.log(JSON.stringify({
      level: 'info',
      msg: 'quote-api listening',
      port: PORT,
      cpuWorkMs: CPU_WORK_MS,
      pid: process.pid,
    }));
  });

  const shutdown = (signal) => {
    console.log(JSON.stringify({ level: 'info', msg: `received ${signal}, draining connections` }));
    app.setReady(false);
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(1), 10000).unref();
  };

  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

module.exports = { createApp, simulateCpuWork };

