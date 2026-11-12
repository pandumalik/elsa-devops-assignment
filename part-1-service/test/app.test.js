'use strict';

const { describe, it, before, after } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { createApp } = require('../src/index');

function request(baseUrl, path) {
  return new Promise((resolve, reject) => {
    http.get(`${baseUrl}${path}`, (res) => {
      let body = '';
      res.on('data', (chunk) => { body += chunk; });
      res.on('end', () => resolve({ statusCode: res.statusCode, headers: res.headers, body }));
    }).on('error', reject);
  });
}

describe('quote-api endpoints', () => {
  let server;
  let baseUrl;

  before(async () => {
    const app = createApp();
    await new Promise((resolve) => {
      server = app.listen(0, '127.0.0.1', resolve);
    });
    const addr = server.address();
    baseUrl = `http://127.0.0.1:${addr.port}`;
  });

  after(async () => {
    if (server) {
      await new Promise((resolve) => server.close(resolve));
    }
  });

  it('GET /healthz returns 200 and status ok', async () => {
    const res = await request(baseUrl, '/healthz');
    assert.equal(res.statusCode, 200);
    const data = JSON.parse(res.body);
    assert.equal(data.status, 'ok');
  });

  it('GET /readyz returns 200 and status ready', async () => {
    const res = await request(baseUrl, '/readyz');
    assert.equal(res.statusCode, 200);
    const data = JSON.parse(res.body);
    assert.equal(data.status, 'ready');
  });

  it('GET /api/quote returns a motivational quote after ~100ms of CPU work', async () => {
    const start = Date.now();
    const res = await request(baseUrl, '/api/quote');
    const elapsed = Date.now() - start;

    assert.equal(res.statusCode, 200);
    const data = JSON.parse(res.body);
    assert.ok(typeof data.quote === 'string' && data.quote.length > 5);
    assert.ok(typeof data.author === 'string' && data.author.length > 2);
    assert.ok(data.cpuWorkMs >= 95, `Expected cpuWorkMs >= 95ms, got ${data.cpuWorkMs}`);
    assert.ok(elapsed >= 90, `Expected wall time >= 90ms, got ${elapsed}ms`);
  });

  it('GET /metrics returns Prometheus metrics including custom counter', async () => {
    const res = await request(baseUrl, '/metrics');
    assert.equal(res.statusCode, 200);
    assert.match(res.body, /quote_api_http_requests_total/);
    assert.match(res.body, /route="\/api\/quote"/);
    assert.match(res.body, /quote_api_http_request_duration_seconds/);
  });

  it('labels unknown paths as route="unmatched" to bound metric cardinality', async () => {
    const notFound = await request(baseUrl, '/random-scan-path-12345');
    assert.equal(notFound.statusCode, 404);
    const res = await request(baseUrl, '/metrics');
    assert.match(res.body, /route="unmatched"/);
    assert.doesNotMatch(res.body, /random-scan-path-12345/);
  });
});

