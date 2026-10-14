const { app } = require('@azure/functions');
const crypto = require('crypto');
const os = require('os');
const { observeInvocation } = require('../lifecycle');

// Shared Application Insights client. On Azure Functions the platform already
// ingests request/trace telemetry when APPLICATIONINSIGHTS_CONNECTION_STRING is
// set; we reuse the default client only to emit a couple of supplementary
// custom metrics/events so the server-side view can be correlated with the load
// test run. We deliberately do NOT flush per request (that would alter the
// workload); the SDK batches in the background.
let aiClient = null;
try {
  const appInsights = require('applicationinsights');
  const conn = process.env.APPLICATIONINSIGHTS_CONNECTION_STRING;
  if (conn && !appInsights.defaultClient) {
    appInsights
      .setup(conn)
      .setAutoCollectConsole(false)
      .setAutoCollectExceptions(true)
      .setSendLiveMetrics(true)
      .setInternalLogging(false, false)
      .start();
  }
  aiClient = appInsights.defaultClient || null;
} catch (err) {
  // applicationinsights is optional; platform telemetry still works without it.
  aiClient = null;
}

// Identifies which hosting plan produced the telemetry so KQL can pivot cleanly
// without relying solely on cloud_RoleName. Set per app in Terraform app settings.
const PLAN = process.env.PLAN_LABEL || 'unknown';

function clampInt(value, def, min, max) {
  const n = parseInt(value, 10);
  if (Number.isNaN(n)) return def;
  return Math.min(Math.max(n, min), max);
}

/**
 * Busy-loop that burns CPU for approximately `cpuMs` milliseconds by hashing.
 * Blocking is intentional: it simulates a CPU-bound workload per invocation.
 */
function burnCpu(cpuMs) {
  const deadline = Date.now() + cpuMs;
  let hash = crypto.createHash('sha256');
  let rounds = 0;
  while (Date.now() < deadline) {
    hash.update(String(rounds));
    // Periodically finalize and re-seed so V8 cannot optimize the loop away.
    if ((rounds & 0x3fff) === 0) {
      hash = crypto.createHash('sha256').update(hash.copy().digest('hex'));
    }
    rounds++;
  }
  return { rounds, digest: hash.digest('hex').slice(0, 12) };
}

/**
 * Allocates and touches `memMB` megabytes of memory and keeps the buffers
 * referenced until the request completes so GC cannot reclaim them early.
 */
function allocateMemory(memMB) {
  const buffers = [];
  const chunkBytes = 1024 * 1024; // 1 MB chunks
  for (let i = 0; i < memMB; i++) {
    const buf = Buffer.allocUnsafe(chunkBytes);
    // Touch every 4KB page so pages are actually committed, not lazily mapped.
    for (let off = 0; off < chunkBytes; off += 4096) {
      buf[off] = (i + off) & 0xff;
    }
    buffers.push(buf);
  }
  // Compute a checksum so the allocation cannot be optimized out.
  let checksum = 0;
  for (const buf of buffers) {
    checksum = (checksum + buf[0] + buf[buf.length - 1]) & 0xffffffff;
  }
  return { buffers, checksum };
}

app.http('stress', {
  methods: ['GET', 'POST'],
  authLevel: 'function',
  route: 'stress',
  handler: async (request, context) => {
    const started = Date.now();
    const lifecycle = observeInvocation();
    const url = new URL(request.url);
    const q = url.searchParams;

    // Workload parameters (bounded to keep a demo safe).
    const cpuMs = clampInt(q.get('cpuMs'), 200, 0, 10000);
    const memMB = clampInt(q.get('memMB'), 128, 0, 512);
    const loops = clampInt(q.get('loops'), 1, 1, 50);
    const runId = q.get('runId') || 'adhoc';
    const phase = q.get('phase') || 'adhoc';
    const sampleId = q.get('sampleId') || context.invocationId;

    let totalRounds = 0;
    let lastDigest = '';
    let memChecksum = 0;

    // Keep a reference to allocated memory for the whole handler lifetime.
    let held = null;
    for (let i = 0; i < loops; i++) {
      const cpu = burnCpu(cpuMs);
      totalRounds += cpu.rounds;
      lastDigest = cpu.digest;
      if (memMB > 0) {
        held = allocateMemory(memMB);
        memChecksum = held.checksum;
      }
    }

    const durationMs = Date.now() - started;
    const mem = process.memoryUsage();

    const dims = {
      plan: PLAN,
      runId,
      cpuMs: String(cpuMs),
      memMB: String(memMB),
      loops: String(loops),
      hostname: os.hostname(),
      phase,
      sampleId,
      invocationId: context.invocationId,
      processBootId: lifecycle.processBootId,
      instanceId: lifecycle.instanceId,
      instanceIdSource: lifecycle.instanceIdSource,
      firstInProcess: String(lifecycle.firstInProcess),
    };

    if (aiClient) {
      aiClient.trackMetric({ name: 'stress_duration_ms', value: durationMs, properties: dims });
      aiClient.trackMetric({ name: 'stress_rss_bytes', value: mem.rss, properties: dims });
      aiClient.trackEvent({
        name: 'stress_completed',
        properties: dims,
        measurements: {
          durationMs, totalRounds,
          invocationSequence: lifecycle.invocationSequence,
          processUptimeMs: lifecycle.processUptimeMs,
        },
      });
    }

    // Release the memory reference now that we have recorded the stress period.
    held = null;

    const body = {
      plan: PLAN,
      runId,
      phase,
      sampleId,
      invocationId: context.invocationId,
      lifecycle,
      durationMs,
      params: { cpuMs, memMB, loops },
      cpuRounds: totalRounds,
      digest: lastDigest,
      memChecksum,
      rssMB: Math.round(mem.rss / (1024 * 1024)),
      instance: os.hostname(),
      timestamp: new Date().toISOString(),
    };

    return {
      status: 200,
      headers: {
        'Content-Type': 'application/json',
        'x-plan': PLAN,
        'x-duration-ms': String(durationMs),
        'x-instance': os.hostname(),
      },
      jsonBody: body,
    };
  },
});
