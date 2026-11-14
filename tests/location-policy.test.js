'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { Readable } = require('node:stream');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { gridCell, shouldSaveAutomatic, checkDelay } = require('../public/location-policy');
const { createApp, openDatabase } = require('../server');

const start = Date.parse('2026-11-14T12:00:00Z');
const point = { latitude: 41.0001, longitude: -87.0001 };
const previous = { ...point, savedAt: new Date(start).toISOString() };

test('same-cell saves wait an hour from the last save, including the exact boundary', () => {
  assert.equal(shouldSaveAutomatic(point, previous, start + 3599999), false);
  assert.equal(shouldSaveAutomatic(point, previous, start + 3600000), true);
  assert.equal(shouldSaveAutomatic(point, previous, start + 7200000), true);
});

test('first check saves; small movement in a cell is skipped; a new cell saves', () => {
  assert.equal(shouldSaveAutomatic(point, null, start), true);
  assert.equal(shouldSaveAutomatic({ latitude: 41.0002, longitude: -87.0002 }, previous, start + 600000), false);
  assert.equal(shouldSaveAutomatic({ ...point, latitude: 41.002 }, previous, start + 600000), true);
});

test('grid boundaries use floor for negative coordinates and distinguish adjacent cells', () => {
  assert.equal(gridCell(-0.0001, 0.0001).south, -0.00125);
  assert.equal(gridCell(-0.0001, 0.0001).west, 0);
  assert.notEqual(gridCell(0, -0.0001).key, gridCell(0, 0.0001).key);
});

test('a skipped check advances cadence; hourly save still becomes eligible', () => {
  const skippedAt = start + 1800000;
  assert.equal(checkDelay(skippedAt + 1, 1800000, skippedAt, start), 1799999);
  assert.equal(checkDelay(start + 3600000, 1800000, skippedAt, start), 0);
  assert.equal(shouldSaveAutomatic(point, previous, start + 3600000), true);
  assert.equal(checkDelay(start + 3600000, 5400000, start, start), 1800000);
});

function browser(storage = new Map(), now = start + 1800000) {
  const elements = new Map();
  const sandbox = vm.createContext({
    LocationCheckIns: require('../public/location-policy'),
    crypto: require('node:crypto').webcrypto,
    Date: class extends Date {
      constructor(...args) { super(...(args.length ? args : [now])); }
      static now() { return now; }
    },
    localStorage: { getItem: (key) => storage.get(key) ?? null, setItem: (key, value) => storage.set(key, value) },
    document: { getElementById: (key) => {
      if (!elements.has(key)) elements.set(key, { value: key === 'interval' ? '30' : '' });
      return elements.get(key);
    } },
  });
  const source = fs.readFileSync(path.join(__dirname, '../public/app.js'), 'utf8');
  vm.runInContext(source.replace(/boot\(\);\s*$/, ''), sandbox);
  return { sandbox, storage, elements };
}

test('browser skipped check does not save; reopening preserves the interval timer', async () => {
  const { sandbox, storage } = browser();
  vm.runInContext(`
    allEntries = [${JSON.stringify({ type: 'location', ...previous })}];
    tracking = true;
    readPosition = async () => ({coords: {latitude: 41.0002, longitude: -87.0002, accuracy: 10}});
    showDeviceOnMap = () => {};
    getJson = () => { throw new Error('A skipped check must not save'); };
  `, sandbox);
  assert.equal(await vm.runInContext('recordPosition()', sandbox), 'skip');
  const reopened = browser(storage, start + 1800001);
  assert.equal(vm.runInContext('msUntilDue()', reopened.sandbox), 1799999);
});

test('preview rejects repeated automatic saves but allows explicit manual saves', () => {
  const { sandbox } = browser(new Map(), Date.now());
  const entry = { type: 'location', ...point, source: 'device', accuracyMeters: 10, manual: true };
  sandbox.entry = entry;
  vm.runInContext('savePreviewEntry(entry)', sandbox);
  vm.runInContext(`
    const rows = readPreviewEntries();
    rows[0].savedAt = new Date(Date.now() - 40 * 60000).toISOString();
    writePreviewEntries(rows);
  `, sandbox);
  assert.throws(() => vm.runInContext('savePreviewEntry({...entry, manual: false})', sandbox), /same grid cell/);
  vm.runInContext('savePreviewEntry(entry)', sandbox);
  assert.equal(vm.runInContext('readPreviewEntries().length', sandbox), 2);
});

test('live map updates never save cell crossings', () => {
  const { sandbox } = browser();
  const markers = [];
  let onPosition;
  sandbox.navigator = { geolocation: { watchPosition: (callback) => { onPosition = callback; return 1; } } };
  sandbox.markers = markers;
  vm.runInContext(`
    tracking = true;
    mapTabOpen = () => true;
    placeHereMarker = (latitude, longitude) => markers.push([latitude, longitude]);
    getJson = () => { throw new Error('Map updates must not save'); };
    startHereWatch();
  `, sandbox);
  onPosition({ coords: point });
  onPosition({ coords: { ...point, latitude: 41.002 } });
  assert.equal(markers.length, 2);
});

async function serverFixture(t) {
  const db = openDatabase(':memory:');
  const handler = createApp(db);
  t.after(() => db.close());
  // Exercise the actual request handler and SQLite store without opening a socket.
  const post = (extra = {}) => new Promise((resolve) => {
    const req = Readable.from([Buffer.from(JSON.stringify({ type: 'location', ...point,
      source: 'device', accuracyMeters: 10, occurredAt: new Date().toISOString(), ...extra }))]);
    req.url = '/api/entries';
    req.method = 'POST';
    req.headers = { 'content-type': 'application/json' };
    const res = {
      headersSent: false,
      writeHead(status) { this.status = status; this.headersSent = true; },
      end(data) { resolve({ status: this.status, body: JSON.parse(data) }); },
    };
    handler(req, res);
  });
  return { db, post };
}

test('server rejects automatic same-cell saves before an hour and allows manual saves', async (t) => {
  const { db, post } = await serverFixture(t);
  assert.equal((await post()).status, 201);
  db.prepare('UPDATE entries SET saved_at = ?').run(new Date(Date.now() - 40 * 60000).toISOString());
  const skipped = await post();
  assert.equal(skipped.status, 429);
  assert.match(skipped.body.error, /same grid cell/);
  assert.equal((await post({ manual: true })).status, 201);
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM entries').get().n, 2);
});

test('server saves a changed cell after the minimum gap and a stationary cell after an hour', async (t) => {
  const { db, post } = await serverFixture(t);
  assert.equal((await post()).status, 201);
  assert.equal((await post({ latitude: 41.002 })).status, 429);
  db.prepare('UPDATE entries SET saved_at = ?').run(new Date(Date.now() - 10 * 60000).toISOString());
  assert.equal((await post({ latitude: 41.002 })).status, 201);
  db.prepare('UPDATE entries SET saved_at = ?').run(new Date(Date.now() - 61 * 60000).toISOString());
  assert.equal((await post({ latitude: 41.002 })).status, 201);
});
