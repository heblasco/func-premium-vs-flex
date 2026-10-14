const { test } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const Module = require('node:module');
const { createLifecycle } = require('../src/lifecycle');
const { validateConfig, measure, percentile, summarize, run, compare } = require('../../scripts/startup-runner');

const key = 'DO-NOT-PERSIST-THIS-KEY';

async function server(t, handler) {
  const instance = http.createServer(handler);
  await new Promise((resolve) => instance.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise((resolve) => { instance.close(resolve); instance.closeAllConnections(); }));
  return `http://127.0.0.1:${instance.address().port}/api/stress`;
}

function target(url, name = 'flex') {
  return { name, url, key, expectedPlan: name, configuration: { sku: name === 'flex' ? 'FC1' : 'EP1', alwaysReady: 0 } };
}

function response(req, observe = createLifecycle()) {
  const q = new URL(req.url, 'http://localhost').searchParams;
  return {
    plan: 'flex', runId: q.get('runId'), phase: q.get('phase'), sampleId: q.get('sampleId'),
    invocationId: randomUUID(), durationMs: 1, lifecycle: observe(),
    params: { cpuMs: Number(q.get('cpuMs')), memMB: Number(q.get('memMB')), loops: Number(q.get('loops')) },
    ignoredSecret: key,
  };
}

const sample = { runId: 'test-run', sampleId: 'test-sample', phase: 'probe', cycle: 1, cpuMs: 0, memMB: 0, loops: 1 };

test('lifecycle tracks first invocation per process, not per run', () => {
  const observe = createLifecycle();
  const first = observe();
  const second = observe();
  assert.equal(first.firstInProcess, true);
  assert.equal(second.firstInProcess, false);
  assert.equal(second.invocationSequence, 2);
  assert.equal(first.processBootId, second.processBootId);
  assert.notEqual(createLifecycle()().processBootId, first.processBootId);
});

test('health consumes shared lifecycle and stress keeps legacy fields and correlated telemetry', async () => {
  const registrations = {};
  const events = [];
  const original = Module._load;
  Module._load = function (id, ...args) {
    if (id === '@azure/functions') return { app: { http: (name, definition) => { registrations[name] = definition; } } };
    if (id === 'applicationinsights') return { defaultClient: {
      trackMetric() {}, trackEvent(event) { events.push(event); },
    } };
    return original.call(this, id, ...args);
  };
  try {
    require('../src/functions/health');
    require('../src/functions/stress');
  } finally { Module._load = original; }
  const health = await registrations.health.handler();
  const stress = await registrations.stress.handler({
    url: 'https://example.test/api/stress?cpuMs=0&memMB=0&loops=1&runId=test&phase=probe&sampleId=sample',
  }, { invocationId: 'invocation' });
  assert.equal(health.jsonBody.lifecycle.firstInProcess, true);
  assert.equal(stress.jsonBody.lifecycle.firstInProcess, false);
  assert.equal(stress.jsonBody.lifecycle.invocationSequence, 2);
  assert.equal(health.jsonBody.lifecycle.processBootId, stress.jsonBody.lifecycle.processBootId);
  for (const field of ['plan', 'runId', 'durationMs', 'params', 'cpuRounds', 'digest', 'memChecksum', 'rssMB', 'instance', 'timestamp']) {
    assert.ok(Object.hasOwn(stress.jsonBody, field), field);
  }
  assert.equal(events[0].properties.sampleId, 'sample');
  assert.equal(events[0].properties.invocationId, 'invocation');
  assert.equal(events[0].properties.firstInProcess, 'false');
  assert.equal(events[0].measurements.invocationSequence, 2);
});

test('measurement records full response, timing and header-only authentication', async (t) => {
  const url = await server(t, (req, res) => {
    assert.equal(req.headers['x-functions-key'], key);
    assert.equal(req.url.includes(key), false);
    const body = JSON.stringify(response(req));
    res.write(body.slice(0, 15));
    setTimeout(() => res.end(body.slice(15)), 25);
  });
  const row = await measure(target(url), sample, 1000);
  assert.equal(row.success, true);
  assert.equal(row.status, 200);
  assert.ok(row.clientMs > row.ttfbMs + 10);
  assert.ok(row.connectMs !== null);
  assert.equal(row.serverMs, 1);
  assert.equal(row.clientMinusHandlerMs, Math.round((row.clientMs - 1) * 100) / 100);
  assert.equal(JSON.stringify(row).includes(key), false);
});

test('HTTP errors, invalid JSON, wrong correlation, oversized bodies and timeouts are failures, never retries', async (t) => {
  for (const mode of ['http-error', 'invalid-json', 'invalid-response', 'response-too-large', 'timeout']) {
    let calls = 0;
    const url = await server(t, (req, res) => {
      calls++;
      if (mode === 'timeout') return;
      if (mode === 'http-error') { res.writeHead(503); return res.end(key); }
      if (mode === 'invalid-json') return res.end(`bad ${key}`);
      if (mode === 'response-too-large') return res.end('x'.repeat(70000));
      const body = response(req);
      body.runId = 'incorrect';
      res.end(JSON.stringify(body));
    });
    const row = await measure(target(url), sample, 100);
    assert.equal(row.error, mode);
    assert.equal(row.success, false);
    assert.equal(row.serverMs, null);
    assert.equal(row.lifecycle, null);
    assert.equal(calls, 1);
    assert.equal(JSON.stringify(row).includes(key), false);
  }
});

test('validation rejects credential URLs, insecure remote targets and unbounded inputs', () => {
  const config = (url, options = {}) => ({ targets: [target(url)], options });
  assert.throws(() => validateConfig(config('https://example.test/api/stress?code=secret')));
  assert.throws(() => validateConfig(config('http://example.test/api/stress')));
  assert.throws(() => validateConfig(config('https://user:secret@example.test/api/stress')));
  assert.throws(() => validateConfig(config('https://example.test/api/stress', { workers: 0 })));
  assert.throws(() => validateConfig(config('https://example.test/api/stress', { samples: NaN })));
});

test('nearest-rank percentiles, failures, warmup exclusions and cohorts are exact', () => {
  assert.equal(percentile([10, 20, 30, 40], 50), 20);
  assert.equal(percentile([10, 20, 30, 40], 95), 40);
  assert.equal(percentile([], 99), null);
  const good = { target: 'flex', phase: 'probe', success: true, clientMs: 20, serverMs: 1, clientMinusHandlerMs: 19,
    lifecycle: { firstInProcess: true, instanceId: 'a', processBootId: 'boot' } };
  const rows = [good, { ...good, success: false, clientMs: 200, lifecycle: null },
    { ...good, phase: 'warmup', clientMs: 10000 }];
  const all = summarize(rows).find((r) => r.cohort === 'all');
  assert.equal(all.attempts, 2);
  assert.equal(all.errors, 1);
  assert.equal(all.p50Ms, 20);
  assert.equal(all.p95Ms, null);
  assert.equal(all.hostIdentifiers, 1);
  assert.equal(summarize(rows).find((r) => r.cohort === 'failed').p50Ms, null);
});

test('idle protocol sends no preflight, persists every invocation and produces comparable artifacts', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'startup-test-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const phases = [];
  const observe = createLifecycle();
  const url = await server(t, (req, res) => {
    phases.push(new URL(req.url, 'http://localhost').searchParams.get('phase'));
    res.end(JSON.stringify(response(req, observe)));
  });
  const settings = { targets: [target(url)], options: { scenario: 'idle-probe', cycles: 2, idleSeconds: 0, samples: 2 } };
  const result = await run(settings, root);
  assert.deepEqual(phases, ['probe', 'followup', 'followup', 'probe', 'followup', 'followup']);
  assert.equal(result.manifest.attemptsIncludingWarmup, 6);
  assert.equal(result.manifest.status, 'completed');
  const rows = fs.readFileSync(path.join(result.directory, 'invocations.jsonl'), 'utf8').trim().split('\n').map(JSON.parse);
  assert.equal(rows.length, 6);
  assert.equal(rows[0].lifecycle.firstInProcess, true);
  assert.equal(rows[3].lifecycle.firstInProcess, false);
  assert.equal(new Set(rows.map((r) => r.sampleId)).size, 6);
  for (const file of fs.readdirSync(result.directory)) {
    assert.equal(fs.readFileSync(path.join(result.directory, file), 'utf8').includes(key), false, file);
  }
  const second = await run(settings, root);
  const comparison = compare([result.directory, second.directory]);
  assert.ok(comparison.includes(result.manifest.runId));
  assert.ok(comparison.includes(second.manifest.runId));
  assert.ok(comparison.includes('alwaysReady'));
});

test('warmup failure persists failure and prevents measured requests', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'startup-test-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  let calls = 0;
  const url = await server(t, (_, res) => { calls++; res.writeHead(403); res.end(); });
  await assert.rejects(run({ targets: [target(url)], options: { scenario: 'warm-baseline' } }, root), /Warm-up failed/);
  assert.equal(calls, 1);
  const directory = path.join(root, fs.readdirSync(root)[0]);
  assert.equal(JSON.parse(fs.readFileSync(path.join(directory, 'manifest.json'))).status, 'failed');
  assert.equal(fs.readFileSync(path.join(directory, 'invocations.jsonl'), 'utf8').trim().split('\n').length, 1);
});

test('burst actually issues concurrent requests and excludes warmup', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'startup-test-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  let active = 0;
  let peak = 0;
  const observe = createLifecycle();
  const url = await server(t, (req, res) => {
    active++; peak = Math.max(peak, active);
    const body = response(req, observe);
    setTimeout(() => { active--; res.end(JSON.stringify(body)); }, 25);
  });
  const result = await run({
    targets: [target(url)], options: { scenario: 'burst', workers: 3, durationSeconds: 1 },
  }, root);
  assert.equal(peak, 3);
  assert.equal(result.summary.some((r) => r.phase === 'warmup'), false);
  assert.equal(result.summary.find((r) => r.cohort === 'all').attempts, result.manifest.attemptsIncludingWarmup - 1);
});
