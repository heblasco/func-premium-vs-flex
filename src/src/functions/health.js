const { app } = require('@azure/functions');
const os = require('os');
const { observeInvocation } = require('../lifecycle');

// Lightweight, anonymous endpoint used to warm the app and verify connectivity
// (e.g. from the load-test subnet) without requiring a function key.
app.http('health', {
  methods: ['GET'],
  authLevel: 'anonymous',
  route: 'health',
  handler: async () => ({
    status: 200,
    jsonBody: {
      status: 'ok',
      plan: process.env.PLAN_LABEL || 'unknown',
      instance: os.hostname(),
      timestamp: new Date().toISOString(),
      lifecycle: observeInvocation(),
    },
  }),
});
