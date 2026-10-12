const fs = require('fs');
const path = require('path');
const vm = require('vm');

const source = fs.readFileSync(path.join(__dirname, '..', 'web', 'app.js'), 'utf8');
const elements = new Map();
const element = () => ({
  textContent: '',
  innerHTML: '',
  className: '',
  value: '',
  checked: false,
  disabled: false,
  addEventListener() {},
  classList: { toggle() {}, add() {}, remove() {} }
});
const document = {
  querySelector(selector) {
    if (!elements.has(selector)) elements.set(selector, element());
    return elements.get(selector);
  },
  querySelectorAll() { return []; },
  addEventListener() {},
  documentElement: element()
};

const status = {
  monitor: { running: true, paused: false },
  total: { sessions: 0, capacityErrors: 0, successes: 0, failures: 0 },
  sessions: [], recent: [], history: { note: '', lastEventAt: null }
};

class FakeEventSource {
  static current = null;
  constructor() {
    this.listeners = new Map();
    this.onerror = null;
    FakeEventSource.current = this;
  }
  addEventListener(name, callback) { this.listeners.set(name, callback); }
  emit(name, event = {}) {
    const callback = this.listeners.get(name);
    if (callback) callback(event);
    if (name === 'error' && this.onerror) this.onerror(event);
  }
}

const context = {
  document,
  EventSource: FakeEventSource,
  fetch: async (url) => ({ ok: true, json: async () => url === '/api/status' ? status : {} }),
  localStorage: { getItem() { return null; }, setItem() {} },
  alert() {},
  console,
  Date, Math, Number, String, Boolean, Array, Object, JSON, Promise, Error,
  setTimeout, clearTimeout
};
vm.runInNewContext(source, context, { filename: 'web/app.js' });

(async () => {
  await new Promise(resolve => setImmediate(resolve));
  const serviceText = elements.get('#serviceText');
  if (!serviceText) throw new Error('serviceText element was not initialized');
  if (serviceText.textContent !== '运行中') {
    throw new Error(`expected initial status 运行中, got ${serviceText.textContent}`);
  }
  FakeEventSource.current.emit('error');
  if (serviceText.textContent !== '运行中') {
    throw new Error(`BUG: process event reconnect overwrote local service status with ${serviceText.textContent}`);
  }
  console.log('PASS service-status-race');
})().catch(error => {
  console.error(error.message);
  process.exitCode = 1;
});
