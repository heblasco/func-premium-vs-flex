'use strict';

const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const https = require('node:https');
const { performance, monitorEventLoopDelay } = require('node:perf_hooks');
const { randomUUID, createHash } = require('node:crypto');

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const round = (n) => Math.round(n * 100) / 100;

function integer(value, min, max, name) {
  if (!Number.isInteger(value) || value < min || value > max) {
    throw new Error(`${name} must be an integer from ${min} to ${max}.`);
  }
  return value;
}

function validateConfig(input) {
  const options = {
    scenario: 'idle-probe', cycles: 5, idleSeconds: 1800, samples: 20,
    workers: 12, durationSeconds: 120, timeoutMs: 120000,
    cpuMs: 0, memMB: 0, loops: 1, ...input.options,
  };
  if (!['idle-probe', 'warm-baseline', 'burst'].includes(options.scenario)) {
    throw new Error('Unknown scenario.');
  }
  for (const [name, min, max] of [
    ['cycles', 1, 100], ['idleSeconds', 0, 86400], ['samples', 1, 10000],
    ['workers', 1, 128], ['durationSeconds', 1, 3600], ['timeoutMs', 1, 230000],
    ['cpuMs', 0, 10000], ['memMB', 0, 512], ['loops', 1, 50],
  ]) integer(options[name], min, max, name);
  if (options.cpuMs * options.loops > 10000) throw new Error('Limit CPU work to 10 seconds per invocation.');
  if (!Array.isArray(input.targets) || input.targets.length < 1 || input.targets.length > 3) {
    throw new Error('Provide one to three targets.');
  }
  const names = new Set();
  const targets = input.targets.map((target) => {
    if (!['flex', 'dedicated', 'elastic-premium'].includes(target.name) || names.has(target.name)) {
      throw new Error('Targets must have unique hosting names.');
    }
    names.add(target.name);
    const url = new URL(target.url);
    if (url.username || url.password || url.search || url.hash || url.pathname !== '/api/stress') {
      throw new Error('Use a clean /api/stress URL without credentials, query or fragment.');
    }
    const local = ['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname);
    if (url.protocol !== 'https:' && !(url.protocol === 'http:' && local)) {
      throw new Error('Targets require HTTPS (HTTP is allowed only on loopback for tests).');
    }
    if (typeof target.key !== 'string' || !target.key) throw new Error('Missing function key.');
    if (!['flex', 'premium', 'elastic-premium'].includes(target.expectedPlan)) throw new Error('Invalid expected plan label.');
    // Whitelist configuration fields: no app settings, keys, or raw ARM payloads.
    const c = target.configuration || {};
    const configuration = {};
    for (const field of ['sku', 'alwaysReady', 'prewarmed', 'alwaysOn', 'maximumInstances',
      'memoryMB', 'httpConcurrency', 'workerProcesses', 'lastModifiedUtc', 'packageSha256']) {
      const value = c[field];
      if (value !== undefined && value !== null && !['string', 'number', 'boolean'].includes(typeof value)) {
        throw new Error(`Invalid configuration field ${field}.`);
      }
      configuration[field] = value ?? null;
    }
    if (target.resourceId !== undefined && !/^\/subscriptions\/[\w-]+\/resourceGroups\/[\w.-]+\/providers\/Microsoft\.Web\/sites\/[\w-]+$/i.test(target.resourceId)) {
      throw new Error('Invalid app resource ID.');
    }
    return { name: target.name, url: url.href, resourceId: target.resourceId ?? null,
      key: target.key, expectedPlan: target.expectedPlan, configuration };
  });
  return { options, targets };
}

function validResponse(body, target, sample) {
  const l = body?.lifecycle;
  return body?.plan === target.expectedPlan && body.runId === sample.runId
    && body.phase === sample.phase && body.sampleId === sample.sampleId
    && typeof body.invocationId === 'string' && /^[\w-]{1,128}$/.test(body.invocationId)
    && Number.isFinite(body.durationMs) && body.durationMs >= 0
    && body.params?.cpuMs === sample.cpuMs && body.params?.memMB === sample.memMB && body.params?.loops === sample.loops
    && typeof l?.processBootId === 'string' && /^[\w-]{1,128}$/.test(l.processBootId)
    && typeof l.instanceId === 'string' && /^[\w.-]{1,256}$/.test(l.instanceId)
    && ['WEBSITE_INSTANCE_ID', 'hostname'].includes(l.instanceIdSource)
    && Number.isInteger(l.invocationSequence) && l.invocationSequence > 0
    && l.firstInProcess === (l.invocationSequence === 1)
    && Number.isFinite(l.processUptimeMs) && l.processUptimeMs >= 0;
}

function measure(target, sample, timeoutMs) {
  return new Promise((resolve) => {
    const url = new URL(target.url);
    for (const field of ['runId', 'phase', 'sampleId', 'cpuMs', 'memMB', 'loops']) {
      url.searchParams.set(field, String(sample[field]));
    }
    const row = {
      schemaVersion: 1, ...sample, target: target.name, startedUtc: new Date().toISOString(),
      status: null, success: false, error: null, clientMs: null, serverMs: null,
      clientMinusHandlerMs: null, lookupMs: null, connectMs: null, tlsMs: null,
      ttfbMs: null, invocationId: null, lifecycle: null,
    };
    const start = performance.now();
    let finished = false;
    let timer;
    const finish = (error) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      row.clientMs ??= round(performance.now() - start);
      row.endedUtc = new Date().toISOString();
      row.error = error;
      row.success = error === null;
      resolve(row);
    };
    // A fresh connection per invocation makes the connection policy identical
    // for probes and follow-ups; connection offsets remain visible in results.
    const req = (url.protocol === 'https:' ? https : http).get(url, {
      agent: false, headers: { 'x-functions-key': target.key },
    }, (res) => {
      row.status = res.statusCode;
      row.ttfbMs = round(performance.now() - start);
      const chunks = [];
      let bytes = 0;
      res.on('data', (chunk) => {
        bytes += chunk.length;
        if (bytes > 65536) {
          finish('response-too-large');
          res.destroy();
        } else chunks.push(chunk);
      });
      res.on('error', () => finish('response-error'));
      res.on('aborted', () => finish('response-aborted'));
      res.on('end', () => {
        if (finished) return;
        row.clientMs = round(performance.now() - start);
        if (res.statusCode !== 200) return finish('http-error');
        let body;
        try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); }
        catch { return finish('invalid-json'); }
        if (!validResponse(body, target, sample)) return finish('invalid-response');
        row.serverMs = body.durationMs;
        row.clientMinusHandlerMs = round(row.clientMs - body.durationMs);
        row.invocationId = body.invocationId;
        const l = body.lifecycle;
        row.lifecycle = {
          processBootId: l.processBootId, instanceId: l.instanceId,
          instanceIdSource: l.instanceIdSource, invocationSequence: l.invocationSequence,
          firstInProcess: l.firstInProcess, processUptimeMs: l.processUptimeMs,
        };
        finish(null);
      });
    });
    req.on('socket', (socket) => {
      socket.once('lookup', () => { row.lookupMs = round(performance.now() - start); });
      socket.once('connect', () => { row.connectMs = round(performance.now() - start); });
      socket.once('secureConnect', () => { row.tlsMs = round(performance.now() - start); });
    });
    req.on('error', () => finish('network-error'));
    timer = setTimeout(() => { finish('timeout'); req.destroy(); }, timeoutMs);
  });
}

function percentile(values, p) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.max(0, Math.ceil(p / 100 * sorted.length) - 1)];
}

function summarize(rows) {
  const groups = new Map();
  for (const row of rows.filter((r) => r.phase !== 'warmup')) {
    for (const cohort of ['all', row.success ? (row.lifecycle.firstInProcess ? 'first-in-process' : 'subsequent') : 'failed']) {
      const key = `${row.target}/${row.phase}/${cohort}`;
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(row);
    }
  }
  return [...groups.entries()].map(([key, group]) => {
    const [target, phase, cohort] = key.split('/');
    const ok = group.filter((r) => r.success);
    const values = ok.map((r) => r.clientMs);
    return {
      target, phase, cohort, attempts: group.length, success: ok.length,
      errors: group.length - ok.length, minMs: values.length ? values.reduce((a, b) => Math.min(a, b)) : null,
      p50Ms: percentile(values, 50),
      p95Ms: phase === 'probe' ? null : percentile(values, 95),
      p99Ms: phase === 'probe' ? null : percentile(values, 99),
      maxMs: values.length ? values.reduce((a, b) => Math.max(a, b)) : null,
      handlerP50Ms: percentile(ok.map((r) => r.serverMs), 50),
      deltaP50Ms: percentile(ok.map((r) => r.clientMinusHandlerMs), 50),
      hostIdentifiers: new Set(ok.map((r) => r.lifecycle.instanceId)).size,
      processes: new Set(ok.map((r) => r.lifecycle.processBootId)).size,
      warning: ok.length < 100 ? 'Small sample; tail estimates are unstable.' : null,
    };
  });
}

function renderTable(summary) {
  const fields = ['target', 'phase', 'cohort', 'attempts', 'success', 'errors',
    'minMs', 'p50Ms', 'p95Ms', 'p99Ms', 'maxMs', 'handlerP50Ms', 'deltaP50Ms', 'hostIdentifiers', 'processes'];
  return [
    `| ${fields.join(' | ')} |`, `| ${fields.map(() => '---').join(' | ')} |`,
    ...summary.map((row) => `| ${fields.map((f) => row[f] ?? '-').join(' | ')} |`),
  ].join('\n');
}

async function run(input, outputDirectory) {
  const { options, targets } = validateConfig(input);
  const runId = `startup-${randomUUID()}`;
  const directory = path.resolve(outputDirectory, runId);
  fs.mkdirSync(directory, { recursive: true });
  const publicTargets = targets.map(({ key, ...target }) => target);
  const configHash = createHash('sha256').update(JSON.stringify(publicTargets)).digest('hex');
  const manifest = {
    schemaVersion: 1, runId, startedUtc: new Date().toISOString(), status: 'running',
    options, targets: publicTargets, configHash, node: process.version, platform: process.platform,
    connectionPolicy: 'new-connection-per-request',
    attribution: 'Process-first is not proof of a platform cold start or prewarmed allocation.',
    percentileMethod: 'nearest-rank; successful responses only; probes omit tail percentiles',
    configurationVerifiedAt: new Date().toISOString(),
    warnings: [
      'No idle period guarantees scale-to-zero. Other traffic invalidates the idle protocol.',
      'Client-minus-handler includes network, queueing and host overhead, not just startup.',
      'Distinct identifiers over a run do not prove concurrent scale-out or prewarmed allocation.',
      'Configuration is a pre-run snapshot; deployment/setting changes during a run invalidate it.',
      'No deployment-age or package-parity guarantee: observe the documented settling period.',
    ],
  };
  const writeManifest = () => fs.writeFileSync(path.join(directory, 'manifest.json'), JSON.stringify(manifest, null, 2));
  writeManifest();
  const logPath = path.join(directory, 'invocations.jsonl');
  fs.writeFileSync(logPath, '');
  const rows = [];
  const lag = monitorEventLoopDelay({ resolution: 20 });
  lag.enable();
  const invoke = async (target, phase, cycle) => {
    const row = await measure(target, {
      runId, sampleId: randomUUID(), phase, cycle,
      cpuMs: options.cpuMs, memMB: options.memMB, loops: options.loops,
    }, options.timeoutMs);
    fs.appendFileSync(logPath, `${JSON.stringify(row)}\n`);
    rows.push(row);
    return row;
  };
  try {
    if (options.scenario === 'idle-probe') {
      for (let cycle = 1; cycle <= options.cycles; cycle++) {
        await sleep(options.idleSeconds * 1000);
        await Promise.all(targets.map(async (target) => {
          await invoke(target, 'probe', cycle);
          for (let i = 0; i < options.samples; i++) await invoke(target, 'followup', cycle);
        }));
      }
    } else {
      const warmup = await Promise.all(targets.map((t) => invoke(t, 'warmup', 0)));
      if (warmup.some((r) => !r.success)) throw new Error('Warm-up failed; see invocation log. No measured phase was started.');
      if (options.scenario === 'warm-baseline') {
        await Promise.all(targets.map(async (target) => {
          for (let i = 0; i < options.samples; i++) await invoke(target, 'warm', 1);
        }));
      } else {
        const deadline = performance.now() + options.durationSeconds * 1000;
        await Promise.all(targets.flatMap((target) => Array.from({ length: options.workers }, async () => {
          while (performance.now() < deadline) await invoke(target, 'burst', 1);
        })));
      }
    }
    manifest.status = rows.some((r) => !r.success) ? 'completed-with-errors' : 'completed';
  } catch (err) {
    manifest.status = 'failed';
    throw err;
  } finally {
    lag.disable();
    manifest.endedUtc = new Date().toISOString();
    manifest.clientEventLoopDelayMaxMs = round(lag.max / 1e6);
    manifest.attemptsIncludingWarmup = rows.length;
    const summary = summarize(rows);
    fs.writeFileSync(path.join(directory, 'summary.json'), JSON.stringify(summary, null, 2));
    const probes = rows.filter((r) => r.phase === 'probe');
    const probeTable = probes.length ? '\n\n## Per-cycle probes\n\n'
      + '| Target | Cycle | Status | Client ms | Handler ms | Delta ms | First in process | Boot ID |\n'
      + '| --- | --- | --- | --- | --- | --- | --- | --- |\n'
      + probes.map((r) => `| ${r.target} | ${r.cycle} | ${r.error || r.status} | ${r.clientMs} | ${r.serverMs ?? '-'} | ${r.clientMinusHandlerMs ?? '-'} | ${r.lifecycle?.firstInProcess ?? '-'} | ${r.lifecycle?.processBootId ?? '-'} |`).join('\n') : '';
    fs.writeFileSync(path.join(directory, 'summary.md'), `# Startup comparison: ${runId}\n\n${renderTable(summary)}${probeTable}\n\n`
      + 'Warm-up excluded. Latencies summarize successes; errors remain in counts and JSONL.\n'
      + 'Probe tails are not reported. Cohorts below 100 successes have unstable tail estimates.\n'
      + 'Host/process counts are observed identifiers, not verified simultaneous scale-out.\n');
    writeManifest();
  }
  return { directory, manifest, summary: summarize(rows) };
}

function compare(directories) {
  if (directories.length < 2) throw new Error('Specify at least two completed run directories.');
  return directories.map((directory) => {
    const manifest = JSON.parse(fs.readFileSync(path.join(directory, 'manifest.json'), 'utf8'));
    const summary = JSON.parse(fs.readFileSync(path.join(directory, 'summary.json'), 'utf8'));
    if (manifest.schemaVersion !== 1 || !['completed', 'completed-with-errors'].includes(manifest.status)) {
      throw new Error('Only completed schema-version 1 runs can be compared.');
    }
    return `## ${manifest.runId} (${manifest.status})\n\n`
      + `Configuration: ${JSON.stringify(manifest.targets.map((t) => ({ target: t.name, ...t.configuration })))}\n\n`
      + `Protocol: ${JSON.stringify(manifest.options)}\n\n`
      + renderTable(summary.filter((s) => s.cohort === 'all'));
  }).join('\n\n') + '\n\nRuns are displayed separately, never pooled. Compare only matching workloads/protocols; configuration differences are intentional experiment factors.\n';
}

if (require.main === module) {
  if (process.argv[2] === '--compare') {
    try { console.log(compare(process.argv.slice(3))); }
    catch { console.error('Comparison failed: check run directories and their manifest/summary files.'); process.exitCode = 1; }
  } else {
    (async () => {
      const raw = process.env.STARTUP_CONFIG;
      delete process.env.STARTUP_CONFIG;
      const result = await run(JSON.parse(raw), process.argv[2] || path.join(__dirname, '..', 'loadtest', 'startup-results'));
      console.log(renderTable(result.summary.filter((s) => s.cohort === 'all')));
      console.log(`Results: ${result.directory}`);
      if (result.manifest.status !== 'completed') process.exitCode = 1;
    })().catch(() => {
      console.error('Startup run failed. Check configuration, connectivity and the persisted run artifacts; no raw errors or credentials are logged.');
      process.exitCode = 1;
    });
  }
}

module.exports = { validateConfig, validResponse, measure, percentile, summarize, renderTable, run, compare };
