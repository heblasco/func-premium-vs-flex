const { randomUUID } = require('node:crypto');
const os = require('node:os');

function createLifecycle() {
  const processBootId = randomUUID();
  const instanceId = process.env.WEBSITE_INSTANCE_ID || os.hostname();
  const instanceIdSource = process.env.WEBSITE_INSTANCE_ID ? 'WEBSITE_INSTANCE_ID' : 'hostname';
  let invocationSequence = 0;
  return () => ({
    processBootId,
    instanceId,
    instanceIdSource,
    processId: process.pid,
    processUptimeMs: Math.round(process.uptime() * 1000),
    invocationSequence: ++invocationSequence,
    firstInProcess: invocationSequence === 1,
  });
}

module.exports = { createLifecycle, observeInvocation: createLifecycle() };
