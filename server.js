'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const { DatabaseSync } = require('node:sqlite');
const { readDailyStepTotals } = require('./health/steps-reader');

const PORT = 3847;
const HOST = '127.0.0.1';
const ROOT = __dirname;
const DATA_DIR = path.join(ROOT, 'data');
const DB_PATH = path.join(DATA_DIR, 'journal.sqlite');
const PUBLIC_DIR = path.join(ROOT, 'public');
const DAY_MS = 24 * 60 * 60 * 1000;
const MIN_LOCATION_GAP_MS = 5 * 60 * 1000;
const TYPES = new Set([
  'location',
  'meal',
  'water',
  'bathroom',
  'life_event',
  'mood',
  'sleep',
  'steps',
]);

class HttpError extends Error {
  constructor(status, message, extra) {
    super(message);
    this.status = status;
    this.extra = extra || null;
  }
}

function round2(n) {
  return Math.round((n + Number.EPSILON) * 100) / 100;
}

function localKey(utcMs, offsetMinutes) {
  return new Date(utcMs - offsetMinutes * 60 * 1000).toISOString().slice(0, 10);
}

function addLocalDays(key, days) {
  const [year, month, day] = key.split('-').map(Number);
  return new Date(Date.UTC(year, month - 1, day + days)).toISOString().slice(0, 10);
}

function buildTrends(entries, days, offsetMinutes, nowMs = Date.now()) {
  if (days !== 7 && days !== 30) {
    throw new HttpError(400, 'days must be 7 or 30.');
  }
  if (!Number.isFinite(offsetMinutes) || offsetMinutes < -840 || offsetMinutes > 840) {
    throw new HttpError(400, 'tzOffsetMinutes is out of range.');
  }

  const todayKey = localKey(nowMs, offsetMinutes);
  const keys = [];
  for (let i = days - 1; i >= 0; i -= 1) keys.push(addLocalDays(todayKey, -i));
  const keySet = new Set(keys);

  const water = new Map(keys.map((key) => [key, 0]));
  const meals = new Map(keys.map((key) => [key, 0]));
  const moodSum = new Map(keys.map((key) => [key, 0]));
  const moodCount = new Map(keys.map((key) => [key, 0]));
  const sleep = new Map(keys.map((key) => [key, 0]));
  const sleepCount = new Map(keys.map((key) => [key, 0]));
  const seen = { water: 0, meal: 0, mood: 0, sleep: 0, steps: 0 };
  let moodTotal = 0;
  let sleepTotal = 0;
  let waterTotal = 0;
  const stepsLatest = new Map();

  for (const entry of entries) {
    const occurred = new Date(entry.occurredAt).getTime();
    if (Number.isNaN(occurred)) continue;
    const key = localKey(occurred, offsetMinutes);
    if (!keySet.has(key)) continue;
    if (entry.type === 'water') {
      water.set(key, water.get(key) + entry.amountMl);
      waterTotal += entry.amountMl;
      seen.water += 1;
    } else if (entry.type === 'meal') {
      meals.set(key, meals.get(key) + 1);
      seen.meal += 1;
    } else if (entry.type === 'mood') {
      moodSum.set(key, moodSum.get(key) + entry.moodScore);
      moodCount.set(key, moodCount.get(key) + 1);
      moodTotal += entry.moodScore;
      seen.mood += 1;
    } else if (entry.type === 'sleep') {
      sleep.set(key, sleep.get(key) + entry.sleepHours);
      sleepCount.set(key, sleepCount.get(key) + 1);
      sleepTotal += entry.sleepHours;
      seen.sleep += 1;
    } else if (entry.type === 'steps' && entry.source === 'apple-health') {
      const savedAt = entry.savedAt || '';
      const previous = stepsLatest.get(key);
      if (!previous || savedAt >= previous.savedAt) {
        stepsLatest.set(key, { stepCount: entry.stepCount, savedAt });
      }
    }
  }

  let stepsTotal = 0;
  for (const day of stepsLatest.values()) stepsTotal += day.stepCount;
  seen.steps = stepsLatest.size;

  const dated = (fill) => keys.map((date) => ({ date, value: fill(date) }));

  return {
    days,
    series: {
      water: {
        empty: seen.water === 0,
        aggregation: 'daily total milliliters',
        entryCount: seen.water,
        totalMl: seen.water ? round2(waterTotal) : 0,
        points: seen.water ? dated((date) => round2(water.get(date))) : [],
      },
      meals: {
        empty: seen.meal === 0,
        aggregation: 'daily count',
        entryCount: seen.meal,
        totalCount: seen.meal,
        points: seen.meal ? dated((date) => meals.get(date)) : [],
      },
      mood: {
        empty: seen.mood === 0,
        aggregation: 'daily average score',
        entryCount: seen.mood,
        average: seen.mood ? round2(moodTotal / seen.mood) : null,
        points: seen.mood
          ? dated((date) => {
              const count = moodCount.get(date);
              return count ? round2(moodSum.get(date) / count) : null;
            })
          : [],
      },
      sleep: {
        empty: seen.sleep === 0,
        aggregation: 'daily hours',
        entryCount: seen.sleep,
        totalHours: seen.sleep ? round2(sleepTotal) : 0,
        points: seen.sleep
          ? dated((date) => (sleepCount.get(date) ? round2(sleep.get(date)) : null))
          : [],
      },
      steps: {
        empty: seen.steps === 0,
        aggregation: 'daily step count',
        entryCount: seen.steps,
        totalSteps: seen.steps ? stepsTotal : 0,
        points: seen.steps
          ? dated((date) => {
              const day = stepsLatest.get(date);
              return day ? day.stepCount : null;
            })
          : [],
      },
    },
  };
}

function searchBlob(entry) {
  const parts = [
    entry.type,
    entry.type === 'life_event' ? 'life event' : entry.type,
    entry.description,
    entry.note,
    entry.title,
    entry.kind,
    entry.source,
  ];
  if (entry.amountMl != null) parts.push(String(entry.amountMl), `${entry.amountMl} ml`);
  if (entry.moodScore != null) parts.push(String(entry.moodScore), `mood ${entry.moodScore}`);
  if (entry.sleepHours != null) parts.push(String(entry.sleepHours), `${entry.sleepHours} hours`);
  if (entry.bristolScale != null) {
    parts.push(String(entry.bristolScale), `bristol ${entry.bristolScale}`);
  }
  if (entry.latitude != null) {
    parts.push(String(entry.latitude), String(entry.longitude), String(entry.accuracyMeters));
    if (entry.altitude != null) parts.push(String(entry.altitude));
  }
  if (entry.stepCount != null) parts.push(String(entry.stepCount), `${entry.stepCount} steps`);
  return parts
    .filter((value) => value != null && String(value).trim() !== '')
    .join('\n')
    .toLowerCase();
}

function toApi(row) {
  const entry = {
    id: row.id,
    type: row.type,
    occurredAt: row.occurred_at,
    savedAt: row.saved_at,
  };
  if (row.type === 'location') {
    entry.latitude = row.latitude;
    entry.longitude = row.longitude;
    entry.accuracyMeters = row.accuracy_meters;
    entry.altitude = row.altitude == null ? null : row.altitude;
    entry.source = row.source;
  } else if (row.type === 'meal') {
    entry.description = row.description;
  } else if (row.type === 'water') {
    entry.amountMl = row.amount_ml;
  } else if (row.type === 'bathroom') {
    entry.kind = row.kind;
    if (row.bristol_scale != null) entry.bristolScale = row.bristol_scale;
    if (row.note != null) entry.note = row.note;
  } else if (row.type === 'life_event') {
    entry.title = row.title;
    if (row.description != null) entry.description = row.description;
  } else if (row.type === 'mood') {
    entry.moodScore = row.mood_score;
    if (row.note != null) entry.note = row.note;
  } else if (row.type === 'sleep') {
    entry.sleepHours = row.sleep_hours;
    if (row.note != null) entry.note = row.note;
  } else if (row.type === 'steps') {
    entry.stepCount = row.step_count;
    entry.source = row.source;
  }
  return entry;
}

function optionalAltitude(value) {
  if (value == null || value === '') return null;
  const altitude = typeof value === 'number' ? value : Number(value);
  if (!Number.isFinite(altitude)) throw new HttpError(400, 'altitude must be a number.');
  return altitude;
}

function requiredString(value, field, max) {
  if (typeof value !== 'string') throw new HttpError(400, `${field} must be text.`);
  const trimmed = value.trim();
  if (!trimmed) throw new HttpError(400, `${field} is required.`);
  if (trimmed.length > max) throw new HttpError(400, `${field} is too long.`);
  return trimmed;
}

function optionalString(value, field, max) {
  if (value == null || value === '') return null;
  if (typeof value !== 'string') throw new HttpError(400, `${field} must be text.`);
  const trimmed = value.trim();
  if (!trimmed) return null;
  if (trimmed.length > max) throw new HttpError(400, `${field} is too long.`);
  return trimmed;
}

function requiredNumber(value, field) {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new HttpError(400, `${field} must be a number.`);
  }
  return value;
}

function parseOccurredAt(value) {
  if (typeof value !== 'string' || !value.trim()) {
    throw new HttpError(400, 'occurredAt is required.');
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) throw new HttpError(400, 'occurredAt is not a valid time.');
  return date.toISOString();
}

function validateEntry(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    throw new HttpError(400, 'Request body must be a JSON object.');
  }
  if (typeof body.type !== 'string' || !TYPES.has(body.type)) {
    throw new HttpError(400, 'type is not a known entry type.');
  }
  const occurredAt = parseOccurredAt(body.occurredAt);
  const base = {
    type: body.type,
    occurredAt,
    latitude: null,
    longitude: null,
    accuracyMeters: null,
    altitude: null,
    source: null,
    description: null,
    amountMl: null,
    kind: null,
    bristolScale: null,
    note: null,
    title: null,
    moodScore: null,
    sleepHours: null,
    stepCount: null,
  };

  if (body.type === 'location') {
    const latitude = requiredNumber(body.latitude, 'latitude');
    const longitude = requiredNumber(body.longitude, 'longitude');
    const accuracyMeters = requiredNumber(body.accuracyMeters, 'accuracyMeters');
    if (latitude < -90 || latitude > 90) throw new HttpError(400, 'latitude is out of range.');
    if (longitude < -180 || longitude > 180) throw new HttpError(400, 'longitude is out of range.');
    if (accuracyMeters < 0) throw new HttpError(400, 'accuracyMeters cannot be negative.');
    if (body.source !== 'device') {
      throw new HttpError(400, 'Location entries are recorded from the device.');
    }
    return {
      ...base,
      latitude,
      longitude,
      accuracyMeters,
      altitude: optionalAltitude(body.altitude),
      source: 'device',
    };
  }

  if (body.type === 'meal') {
    return { ...base, description: requiredString(body.description, 'description', 4000) };
  }

  if (body.type === 'water') {
    const amountMl = requiredNumber(body.amountMl, 'amountMl');
    if (amountMl <= 0 || amountMl > 20000) {
      throw new HttpError(400, 'amountMl must be greater than 0 and at most 20000.');
    }
    return { ...base, amountMl };
  }

  if (body.type === 'bathroom') {
    if (body.kind !== 'stool' && body.kind !== 'urine') {
      throw new HttpError(400, 'kind must be stool or urine.');
    }
    let bristolScale = null;
    if (body.bristolScale != null && body.bristolScale !== '') {
      if (body.kind !== 'stool') {
        throw new HttpError(400, 'Bristol scale is only for stool.');
      }
      if (!Number.isInteger(body.bristolScale) || body.bristolScale < 1 || body.bristolScale > 7) {
        throw new HttpError(400, 'bristolScale must be an integer from 1 to 7.');
      }
      bristolScale = body.bristolScale;
    }
    return {
      ...base,
      kind: body.kind,
      bristolScale,
      note: optionalString(body.note, 'note', 2000),
    };
  }

  if (body.type === 'life_event') {
    return {
      ...base,
      title: requiredString(body.title, 'title', 200),
      description: requiredString(body.description, 'description', 4000),
    };
  }

  if (body.type === 'steps') {
    if (body.source !== 'apple-health') {
      throw new HttpError(400, 'Step totals come from Apple Health.');
    }
    if (!Number.isInteger(body.stepCount) || body.stepCount < 0 || body.stepCount > 500000) {
      throw new HttpError(400, 'stepCount must be a whole number from 0 to 500000.');
    }
    return {
      ...base,
      stepCount: body.stepCount,
      source: 'apple-health',
    };
  }

  if (body.type === 'mood') {
    if (!Number.isInteger(body.moodScore) || body.moodScore < 1 || body.moodScore > 5) {
      throw new HttpError(400, 'moodScore must be an integer from 1 to 5.');
    }
    return {
      ...base,
      moodScore: body.moodScore,
      note: optionalString(body.note, 'note', 2000),
    };
  }

  const sleepHours = requiredNumber(body.sleepHours, 'sleepHours');
  if (sleepHours <= 0 || sleepHours > 24) {
    throw new HttpError(400, 'sleepHours must be greater than 0 and at most 24.');
  }
  return {
    ...base,
    sleepHours,
    note: optionalString(body.note, 'note', 2000),
  };
}

function contentType(file) {
  switch (path.extname(file).toLowerCase()) {
    case '.html':
      return 'text/html; charset=utf-8';
    case '.js':
      return 'text/javascript; charset=utf-8';
    case '.css':
      return 'text/css; charset=utf-8';
    case '.png':
      return 'image/png';
    case '.svg':
      return 'image/svg+xml';
    case '.json':
      return 'application/json';
    case '.ico':
      return 'image/x-icon';
    default:
      return 'application/octet-stream';
  }
}

function chartBundlePath() {
  const candidates = [
    path.join(ROOT, 'node_modules/chart.js/dist/chart.umd.js'),
    path.join(ROOT, 'node_modules/chart.js/dist/chart.umd.min.js'),
  ];
  return candidates.find((file) => fs.existsSync(file)) || null;
}

function resolveVendor(urlPath) {
  if (urlPath === '/vendor/chart.umd.js') return chartBundlePath();
  if (urlPath === '/vendor/leaflet/leaflet.js') {
    return path.join(ROOT, 'node_modules/leaflet/dist/leaflet.js');
  }
  if (urlPath === '/vendor/leaflet/leaflet.css') {
    return path.join(ROOT, 'node_modules/leaflet/dist/leaflet.css');
  }
  const prefix = '/vendor/leaflet/images/';
  if (urlPath.startsWith(prefix)) {
    const name = urlPath.slice(prefix.length);
    if (!/^[\w.-]+$/.test(name)) return null;
    return path.join(ROOT, 'node_modules/leaflet/dist/images', name);
  }
  return null;
}

function resolvePublic(urlPath) {
  let decoded;
  try {
    decoded = decodeURIComponent(urlPath);
  } catch {
    return null;
  }
  if (decoded.includes('\0')) return null;
  const rel = decoded.replace(/^\/+/, '');
  const full = path.resolve(PUBLIC_DIR, rel);
  if (full !== PUBLIC_DIR && !full.startsWith(`${PUBLIC_DIR}${path.sep}`)) return null;
  return full;
}

function sendJson(res, status, payload) {
  const data = JSON.stringify(payload);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(data),
    'Cache-Control': 'no-store',
  });
  res.end(data);
}

function sendText(res, status, message) {
  const data = Buffer.from(message);
  res.writeHead(status, {
    'Content-Type': 'text/plain; charset=utf-8',
    'Content-Length': data.length,
    'Cache-Control': 'no-store',
  });
  res.end(data);
}

function sendFile(res, file, method) {
  fs.stat(file, (err, stat) => {
    if (err || !stat.isFile()) {
      sendText(res, 404, 'Not found');
      return;
    }
    fs.readFile(file, (readErr, buf) => {
      if (readErr) {
        sendText(res, 500, 'Could not read file');
        return;
      }
      res.writeHead(200, {
        'Content-Type': contentType(file),
        'Content-Length': buf.length,
        'Cache-Control': 'no-cache',
      });
      if (method === 'HEAD') res.end();
      else res.end(buf);
    });
  });
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    let failed = false;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > 1_000_000) {
        failed = true;
        reject(new HttpError(413, 'Request is too large.'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (!failed) resolve(Buffer.concat(chunks).toString('utf8'));
    });
    req.on('error', (error) => {
      if (!failed) reject(error);
    });
  });
}

function openDatabase() {
  fs.mkdirSync(DATA_DIR, { recursive: true });
  const db = new DatabaseSync(DB_PATH);
  db.exec('PRAGMA journal_mode = WAL');
  db.exec('PRAGMA busy_timeout = 3000');
  db.exec(`
    CREATE TABLE IF NOT EXISTS entries (
      id TEXT PRIMARY KEY,
      type TEXT NOT NULL,
      occurred_at TEXT NOT NULL,
      saved_at TEXT NOT NULL,
      latitude REAL,
      longitude REAL,
      accuracy_meters REAL,
      altitude REAL,
      source TEXT,
      description TEXT,
      amount_ml REAL,
      kind TEXT,
      bristol_scale INTEGER,
      note TEXT,
      title TEXT,
      mood_score INTEGER,
      sleep_hours REAL,
      step_count INTEGER
    )
  `);
  const columns = db.prepare('PRAGMA table_info(entries)').all();
  if (!columns.some((column) => column.name === 'step_count')) {
    db.exec('ALTER TABLE entries ADD COLUMN step_count INTEGER');
  }
  if (!columns.some((column) => column.name === 'altitude')) {
    db.exec('ALTER TABLE entries ADD COLUMN altitude REAL');
  }
  db.exec('CREATE INDEX IF NOT EXISTS entries_occurred ON entries (occurred_at DESC, saved_at DESC)');
  return db;
}

function createApp(db) {
  const insert = db.prepare(`
    INSERT INTO entries (
      id, type, occurred_at, saved_at,
      latitude, longitude, accuracy_meters, altitude, source,
      description, amount_ml, kind, bristol_scale, note, title,
      mood_score, sleep_hours, step_count
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);
  const updateSteps = db.prepare(`
    UPDATE entries
    SET step_count = ?, occurred_at = ?, saved_at = ?, source = 'apple-health'
    WHERE id = ?
  `);
  const findStepsDay = db.prepare(`
    SELECT id FROM entries
    WHERE type = 'steps' AND source = 'apple-health' AND substr(occurred_at, 1, 10) = ?
    ORDER BY saved_at DESC
    LIMIT 1
  `);
  const selectById = db.prepare('SELECT * FROM entries WHERE id = ?');
  const selectAll = db.prepare(
    'SELECT * FROM entries ORDER BY occurred_at DESC, saved_at DESC, id DESC'
  );
  const latestLocation = db.prepare(
    "SELECT saved_at FROM entries WHERE type = 'location' ORDER BY saved_at DESC LIMIT 1"
  );

  let writeChain = Promise.resolve();
  function withWriteLock(fn) {
    const run = writeChain.then(() => fn());
    writeChain = run.then(
      () => {},
      () => {}
    );
    return run;
  }

  function listEntries(query) {
    const entries = selectAll.all().map(toApi);
    const needle = String(query || '').trim().toLowerCase();
    if (!needle) return entries;
    return entries.filter((entry) => searchBlob(entry).includes(needle));
  }

  function insertEntry(body) {
    const value = validateEntry(body);
    const now = new Date();
    if (value.type === 'location') {
      const previous = latestLocation.get();
      if (previous) {
        const elapsed = now.getTime() - new Date(previous.saved_at).getTime();
        if (elapsed < MIN_LOCATION_GAP_MS) {
          throw new HttpError(429, 'Location check-ins are limited to one every 5 minutes.', {
            retryAfterSeconds: Math.ceil((MIN_LOCATION_GAP_MS - elapsed) / 1000),
          });
        }
      }
    }
    const savedAt = now.toISOString();
    if (value.type === 'steps') {
      const day = value.occurredAt.slice(0, 10);
      const existing = findStepsDay.get(day);
      if (existing) {
        updateSteps.run(value.stepCount, value.occurredAt, savedAt, existing.id);
        return toApi(selectById.get(existing.id));
      }
    }
    const id = crypto.randomUUID();
    insert.run(
      id,
      value.type,
      value.occurredAt,
      savedAt,
      value.latitude,
      value.longitude,
      value.accuracyMeters,
      value.altitude,
      value.source,
      value.description,
      value.amountMl,
      value.kind,
      value.bristolScale,
      value.note,
      value.title,
      value.moodScore,
      value.sleepHours,
      value.stepCount
    );
    return toApi(selectById.get(id));
  }

  async function handleEntries(req, res, url) {
    if (req.method === 'GET') {
      sendJson(res, 200, { entries: listEntries(url.searchParams.get('q')) });
      return;
    }
    if (req.method !== 'POST') throw new HttpError(405, 'Method not allowed.');
    const type = req.headers['content-type'] || '';
    if (!type.includes('application/json')) {
      throw new HttpError(415, 'Content-Type must be application/json.');
    }
    const raw = await readBody(req);
    let body;
    try {
      body = JSON.parse(raw || '');
    } catch {
      throw new HttpError(400, 'Request body must be JSON.');
    }
    const entry = await withWriteLock(() => insertEntry(body));
    sendJson(res, 201, { entry });
  }

  function handleTrends(req, res, url) {
    if (req.method !== 'GET') throw new HttpError(405, 'Method not allowed.');
    const days = Number(url.searchParams.get('days'));
    const offsetRaw = url.searchParams.get('tzOffsetMinutes');
    const offsetMinutes = offsetRaw == null || offsetRaw === ''
      ? new Date().getTimezoneOffset()
      : Number(offsetRaw);
    const entries = selectAll.all().map(toApi);
    sendJson(res, 200, buildTrends(entries, days, offsetMinutes));
  }

  const ANALYZE_MODELS = {
    'Opus 5.5': { provider: 'anthropic', id: 'claude-opus-5-5' },
    'Grok 4.7': { provider: 'xai', id: 'grok-4.7' },
    'GPT 6.1': { provider: 'openai', id: 'gpt-6.1-sol' },
  };

  function locationPrompt(question, locations) {
    const rows = locations.map((item) => ({
      latitude: item.latitude,
      longitude: item.longitude,
      accuracy: item.accuracy,
      time: item.time,
      altitude: item.altitude,
    }));
    return `Answer the question using only these location check-ins. Each item has latitude, longitude, accuracy in meters, time, and altitude in meters or null.\n\nQuestion: ${question}\n\nLocations:\n${JSON.stringify(rows)}`;
  }

  function providerText(payload) {
    if (!payload || typeof payload !== 'object') return '';
    if (Array.isArray(payload.content)) {
      return payload.content
        .filter((block) => block && block.type === 'text' && typeof block.text === 'string')
        .map((block) => block.text)
        .join('\n')
        .trim();
    }
    if (typeof payload.output_text === 'string' && payload.output_text.trim()) return payload.output_text.trim();
    if (Array.isArray(payload.output)) {
      const bits = [];
      for (const item of payload.output) {
        const content = item && Array.isArray(item.content) ? item.content : [];
        for (const part of content) {
          if (part && part.type === 'output_text' && typeof part.text === 'string') bits.push(part.text);
        }
      }
      if (bits.length) return bits.join('\n').trim();
    }
    const content = payload.choices && payload.choices[0] && payload.choices[0].message
      ? payload.choices[0].message.content
      : '';
    if (typeof content === 'string') return content.trim();
    if (Array.isArray(content)) {
      return content.map((part) => (part && typeof part.text === 'string' ? part.text : '')).join('\n').trim();
    }
    return '';
  }

  async function forwardAnalysis(choice, apiKey, question, locations) {
    const prompt = locationPrompt(question, locations);
    const headers = { 'Content-Type': 'application/json' };
    let url;
    let body;
    if (choice.provider === 'anthropic') {
      url = 'https://api.anthropic.com/v1/messages';
      headers['x-api-key'] = apiKey;
      headers['anthropic-version'] = '2023-06-01';
      body = {
        model: choice.id,
        max_tokens: 2048,
        messages: [{ role: 'user', content: prompt }],
      };
    } else if (choice.provider === 'xai') {
      url = 'https://api.x.ai/v1/responses';
      headers.Authorization = `Bearer ${apiKey}`;
      body = {
        model: choice.id,
        input: prompt,
        store: false,
      };
    } else {
      url = 'https://api.openai.com/v1/chat/completions';
      headers.Authorization = `Bearer ${apiKey}`;
      body = {
        model: choice.id,
        messages: [{ role: 'user', content: prompt }],
      };
    }
    let response;
    try {
      response = await fetch(url, {
        method: 'POST',
        headers,
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(60000),
      });
    } catch {
      throw new HttpError(502, 'The provider could not be reached.');
    }
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      const raw = payload && payload.error
        ? (payload.error.message || payload.error.type || 'The provider rejected the request.')
        : 'The provider rejected the request.';
      const message = String(raw).includes(apiKey) ? 'The provider rejected the request.' : String(raw).slice(0, 500);
      throw new HttpError(502, message);
    }
    const analysis = providerText(payload);
    if (!analysis) throw new HttpError(502, 'The provider returned no text.');
    return analysis;
  }

  function cleanLocations(value) {
    if (!Array.isArray(value)) throw new HttpError(400, 'locations must be a list.');
    return value.slice(0, 2000).map((item) => {
      if (!item || typeof item !== 'object') throw new HttpError(400, 'A location check-in is not valid.');
      const latitude = Number(item.latitude);
      const longitude = Number(item.longitude);
      if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) {
        throw new HttpError(400, 'A location check-in is missing coordinates.');
      }
      const accuracy = item.accuracy == null || item.accuracy === '' ? null : Number(item.accuracy);
      const altitude = item.altitude == null || item.altitude === '' ? null : Number(item.altitude);
      return {
        latitude,
        longitude,
        accuracy: Number.isFinite(accuracy) ? accuracy : null,
        time: typeof item.time === 'string' ? item.time : null,
        altitude: Number.isFinite(altitude) ? altitude : null,
      };
    });
  }

  async function handleAnalyze(req, res) {
    if (req.method !== 'POST') throw new HttpError(405, 'Method not allowed.');
    let body;
    try {
      body = JSON.parse(await readBody(req));
    } catch (error) {
      if (error instanceof HttpError) throw error;
      throw new HttpError(400, 'Request body must be JSON.');
    }
    if (body && body.probe === true) {
      sendJson(res, 200, { proxy: true });
      return;
    }
    const choice = ANALYZE_MODELS[body && body.model];
    if (!choice) throw new HttpError(400, 'Choose Opus 5.5, Grok 4.7, or GPT 6.1.');
    const apiKey = typeof (body && body.apiKey) === 'string' ? body.apiKey.trim() : '';
    if (!apiKey) throw new HttpError(400, 'The key for that model is missing.');
    const question = typeof (body && body.question) === 'string' ? body.question.trim() : '';
    if (!question) throw new HttpError(400, 'Enter a question.');
    const locations = cleanLocations(body.locations);
    const analysis = await forwardAnalysis(choice, apiKey, question, locations);
    sendJson(res, 200, { analysis, model: choice.id });
  }

  function handleStepsReading(req, res) {
    if (req.method !== 'GET') throw new HttpError(405, 'Method not allowed.');
    const reading = readDailyStepTotals();
    sendJson(res, 200, {
      available: false,
      executed: false,
      saved: false,
      reason: reading.reason,
    });
  }

  function route(req, res) {
    const url = new URL(req.url, `http://${req.headers.host || `${HOST}:${PORT}`}`);
    if (url.pathname === '/api/entries') return handleEntries(req, res, url);
    if (url.pathname === '/api/trends') return handleTrends(req, res, url);
    if (url.pathname === '/api/steps/reading') return handleStepsReading(req, res);
    if (url.pathname === '/api/analyze') return handleAnalyze(req, res);
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      throw new HttpError(405, 'Method not allowed.');
    }
    if (url.pathname === '/favicon.ico') {
      res.writeHead(204, { 'Cache-Control': 'no-store' });
      res.end();
      return undefined;
    }
    const vendor = resolveVendor(url.pathname);
    if (vendor) {
      sendFile(res, vendor, req.method);
      return undefined;
    }
    if (url.pathname.startsWith('/api/')) throw new HttpError(404, 'Not found.');
    const rel = url.pathname === '/' ? '/index.html' : url.pathname;
    const file = resolvePublic(rel);
    if (!file) {
      sendText(res, 400, 'Bad path');
      return undefined;
    }
    sendFile(res, file, req.method);
    return undefined;
  }

  return function onRequest(req, res) {
    Promise.resolve()
      .then(() => route(req, res))
      .catch((error) => {
        if (res.headersSent) return;
        const status = error.status || 500;
        const payload = {
          error: status === 500 ? 'Something went wrong.' : error.message,
        };
        if (error.extra) Object.assign(payload, error.extra);
        if (status === 500) console.error(error);
        sendJson(res, status, payload);
      });
  };
}

function main() {
  const chart = chartBundlePath();
  const leaflet = path.join(ROOT, 'node_modules/leaflet/dist/leaflet.js');
  if (!chart || !fs.existsSync(leaflet)) {
    console.error('Chart.js or Leaflet is missing. Run npm install in /agent.');
    process.exit(1);
  }
  const db = openDatabase();
  const server = http.createServer(createApp(db));
  server.on('error', (error) => {
    if (error.code === 'EADDRINUSE') console.error(`Port ${PORT} is already in use.`);
    else console.error(error);
    process.exit(1);
  });
  function shutdown() {
    server.close();
    try {
      db.close();
    } catch {
      // The process is exiting.
    }
    process.exit(0);
  }
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
  server.listen(PORT, HOST, () => {
    console.log(`Fully Tracked listening at http://${HOST}:${PORT}`);
  });
}

module.exports = {
  buildTrends,
  searchBlob,
  MIN_LOCATION_GAP_MS,
};

if (require.main === module) main();
