'use strict';

const MIN_MINUTES = 5;
const MAX_MINUTES = 7 * 24 * 60;
const DEFAULT_MINUTES = 30;
const TRACK_KEY = 'fully-tracked-location';
const INTERVAL_KEY = 'fully-tracked-interval-min';

const TYPE_LABELS = {
  location: 'Location',
  meal: 'Meal',
  water: 'Water',
  bathroom: 'Bathroom',
  life_event: 'Life event',
  mood: 'Mood',
  sleep: 'Sleep',
  steps: 'Steps',
};

const CHARTS = {
  water: { color: '#8aa4b5', kind: 'bar', label: 'ml' },
  meals: { color: '#c4896a', kind: 'bar', label: 'meals' },
  mood: { color: '#9caf96', kind: 'line', label: 'score' },
  sleep: { color: '#d4b896', kind: 'line', label: 'hours' },
  steps: { color: '#c4a484', kind: 'bar', label: 'steps' },
};

const chartInstances = { water: null, meals: null, mood: null, sleep: null, steps: null };
const STEPS_READ_MS = 30 * 60 * 1000;
let stepsTimer = null;
let rangeDays = 7;
let activeMetric = 'water';
let allEntries = [];
let tracking = false;
let recording = false;
let timer = null;
let listToken = 0;
let trendsToken = 0;
let dataToken = 0;
let map = null;
let markerLayer = null;
let mapNote = 'Allow location to center this map. Visited cells darken with each check-in.';
let mappedCount = -1;

const intervalInput = document.getElementById('interval');
const trackStatus = document.getElementById('track-status');
let wakeLock = null;
const searchInput = document.getElementById('q');
const banner = document.getElementById('banner');

function showBanner(message) {
  banner.hidden = !message;
  banner.textContent = message || '';
}

function offlinePreview(error) {
  return Boolean(error && (error.status === 404 || error.status === 405));
}

function showOfflinePreview() {
  allEntries = [];
  renderList([], '');
  renderMap([]);
  renderCorrelations();
  document.querySelectorAll('.chart-card').forEach((card) => {
    const empty = card.querySelector('.chart-empty');
    const wrap = card.querySelector('.chart-wrap');
    if (empty) {
      empty.hidden = false;
      empty.textContent = 'No entries in this preview.';
    }
    if (wrap) wrap.hidden = true;
  });
  showMetric(activeMetric);
}

function formatNum(value) {
  if (value == null || Number.isNaN(value)) return '';
  const rounded = Math.round(value * 100) / 100;
  return String(rounded);
}

function formatWhen(iso) {
  return new Date(iso).toLocaleString(undefined, {
    dateStyle: 'medium',
    timeStyle: 'short',
  });
}

function formatClock(date) {
  return date.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
}

function toDatetimeLocal(date) {
  const pad = (n) => String(n).padStart(2, '0');
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

function fromDatetimeLocal(value) {
  if (!value) throw new Error('Enter when it happened.');
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) throw new Error('Enter a valid time.');
  return date.toISOString();
}

function setDefaultTimes() {
  const value = toDatetimeLocal(new Date());
  document.querySelectorAll('input[type="datetime-local"]').forEach((input) => {
    if (!input.value) input.value = value;
  });
}

const PREVIEW_ENTRIES_KEY = 'fully-tracked-preview-entries';

function readPreviewEntries() {
  try {
    const parsed = JSON.parse(localStorage.getItem(PREVIEW_ENTRIES_KEY) || '[]');
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

function writePreviewEntries(entries) {
  localStorage.setItem(PREVIEW_ENTRIES_KEY, JSON.stringify(entries));
}

function previewUrl(url) {
  return new URL(url, 'https://preview.local');
}

function previewEntriesResponse(url) {
  const needle = (previewUrl(url).searchParams.get('q') || '').trim().toLowerCase();
  const entries = readPreviewEntries();
  if (!needle) return { entries };
  return {
    entries: entries.filter((entry) => JSON.stringify(entry).toLowerCase().includes(needle)),
  };
}

function savePreviewEntry(body) {
  const entries = readPreviewEntries();
  if (body.type === 'location') {
    const latest = entries
      .filter((entry) => entry.type === 'location')
      .reduce((max, entry) => Math.max(max, new Date(entry.savedAt).getTime()), 0);
    if (latest && Date.now() - latest < intervalMs()) {
      const error = new Error('A check-in is already recent.');
      error.status = 429;
      throw error;
    }
  }
  const entry = {
    id: typeof crypto !== 'undefined' && crypto.randomUUID ? crypto.randomUUID() : String(Date.now()),
    savedAt: new Date().toISOString(),
    ...body,
  };
  entries.unshift(entry);
  writePreviewEntries(entries);
  return entry;
}

function emptyTrends(days) {
  const blank = { empty: true, points: [], entryCount: 0 };
  return {
    days,
    series: {
      water: { ...blank, totalMl: 0 },
      meals: { ...blank, totalCount: 0 },
      mood: { ...blank, average: null },
      sleep: { ...blank, totalHours: 0 },
      steps: { ...blank, totalSteps: 0 },
    },
  };
}

function localApi(url, options) {
  const path = url.split('?')[0];
  const method = ((options && options.method) || 'GET').toUpperCase();
  if (path === '/api/entries' && method === 'GET') return previewEntriesResponse(url);
  if (path === '/api/entries' && method === 'POST') return savePreviewEntry(JSON.parse(options.body));
  if (path === '/api/trends' && method === 'GET') {
    return emptyTrends(Number(previewUrl(url).searchParams.get('days')) || 7);
  }
  const error = new Error('Request failed.');
  error.status = 404;
  throw error;
}

async function getJson(url, options) {
  let response;
  try {
    response = await fetch(url, { cache: 'no-store', ...options });
  } catch {
    throw new Error('Could not reach the server.');
  }
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    if (response.status === 404 || response.status === 405) return localApi(url, options);
    const error = new Error(data.error || 'Request failed.');
    error.status = response.status;
    error.payload = data;
    throw error;
  }
  return data;
}

function entryLines(entry) {
  if (entry.type === 'location') {
    return [
      `${entry.latitude.toFixed(5)}, ${entry.longitude.toFixed(5)} · ±${Math.round(entry.accuracyMeters)} m · device`,
    ];
  }
  if (entry.type === 'meal') return [entry.description];
  if (entry.type === 'water') return [`${formatNum(entry.amountMl)} ml`];
  if (entry.type === 'bathroom') {
    const bits = [entry.kind === 'stool' ? 'Stool' : 'Urine'];
    if (entry.bristolScale != null) bits.push(`Bristol ${entry.bristolScale}`);
    const lines = [bits.join(' · ')];
    if (entry.note) lines.push(entry.note);
    return lines;
  }
  if (entry.type === 'life_event') {
    const lines = [entry.title];
    if (entry.description) lines.push(entry.description);
    return lines;
  }
  if (entry.type === 'mood') {
    const lines = [`${entry.moodScore} / 5`];
    if (entry.note) lines.push(entry.note);
    return lines;
  }
  if (entry.type === 'steps') {
    return [`${Number(entry.stepCount).toLocaleString()} steps · ${entry.source}`];
  }
  const lines = [`${formatNum(entry.sleepHours)} hours`];
  if (entry.note) lines.push(entry.note);
  return lines;
}

function renderList(entries, query) {
  const list = document.getElementById('entries');
  const empty = document.getElementById('entries-empty');
  const count = document.getElementById('entries-count');
  list.replaceChildren();
  const trimmed = query.trim();
  if (!entries.length) {
    count.textContent = '';
    empty.hidden = false;
    empty.textContent = trimmed
      ? `No entries match “${trimmed}”.`
      : 'Nothing here yet. Location check-ins appear when tracking is on. Meals, water, bathroom, life events, mood, and sleep can be added by hand.';
    return;
  }
  empty.hidden = true;
  count.textContent = trimmed
    ? `${entries.length} match${entries.length === 1 ? '' : 'es'}`
    : `${entries.length} entr${entries.length === 1 ? 'y' : 'ies'}`;
  for (const entry of entries) {
    const article = document.createElement('article');
    article.className = 'entry';
    article.dataset.type = entry.type;
    const header = document.createElement('header');
    const type = document.createElement('span');
    type.className = 'type';
    type.textContent = TYPE_LABELS[entry.type] || entry.type;
    const when = document.createElement('time');
    when.className = 'when';
    when.dateTime = entry.occurredAt;
    when.textContent = formatWhen(entry.occurredAt);
    header.append(type, when);
    article.append(header);
    for (const line of entryLines(entry)) {
      const p = document.createElement('p');
      p.className = 'summary';
      p.textContent = line;
      article.append(p);
    }
    const saved = document.createElement('p');
    saved.className = 'saved';
    saved.textContent = `Saved ${formatWhen(entry.savedAt)}`;
    article.append(saved);
    list.append(article);
  }
}

function destroyChart(key) {
  if (chartInstances[key]) {
    chartInstances[key].destroy();
    chartInstances[key] = null;
  }
}

function chartSummary(key, series) {
  if (key === 'water') return `${formatNum(series.totalMl)} ml total`;
  if (key === 'meals') return series.totalCount === 1 ? '1 meal' : `${series.totalCount} meals`;
  if (key === 'mood') return `Average ${formatNum(series.average)}`;
  if (key === 'steps') return `${Number(series.totalSteps).toLocaleString()} steps across logged days`;
  return `${formatNum(series.totalHours)} hours total`;
}

function emptyChartMessage(key, days) {
  const span = `the last ${days} days`;
  if (key === 'water') return `No water logged in ${span}.`;
  if (key === 'meals') return `No meals logged in ${span}.`;
  if (key === 'mood') return `No mood scores in ${span}.`;
  if (key === 'steps') return `No step totals in ${span}. Apple Health is not available in this preview, so no count is filled in.`;
  return `No sleep logged in ${span}.`;
}

function renderTrends(payload) {
  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  for (const key of Object.keys(CHARTS)) {
    const card = document.querySelector(`[data-chart="${key}"]`);
    const series = payload.series[key];
    const empty = card.querySelector('.chart-empty');
    const wrap = card.querySelector('.chart-wrap');
    const summary = card.querySelector('.chart-summary');
    const canvas = card.querySelector('canvas');
    if (series.empty) {
      destroyChart(key);
      empty.hidden = false;
      empty.textContent = emptyChartMessage(key, payload.days);
      wrap.hidden = true;
      summary.textContent = '';
      continue;
    }
    empty.hidden = true;
    wrap.hidden = false;
    summary.textContent = chartSummary(key, series);
    const labels = series.points.map((point) => {
      const [year, month, day] = point.date.split('-').map(Number);
      return new Date(year, month - 1, day).toLocaleDateString(undefined, payload.days === 7
        ? { weekday: 'short', day: 'numeric' }
        : { month: 'short', day: 'numeric' });
    });
    const spec = CHARTS[key];
    destroyChart(key);
    chartInstances[key] = new Chart(canvas, {
      type: spec.kind,
      data: {
        labels,
        datasets: [
          {
            label: spec.label,
            data: series.points.map((point) => point.value),
            backgroundColor: spec.color,
            borderColor: spec.color,
            borderWidth: spec.kind === 'line' ? 2 : 0,
            pointRadius: 3,
            spanGaps: false,
            tension: 0,
          },
        ],
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        animation: reduce ? false : { duration: 400 },
        plugins: { legend: { display: false } },
        scales: {
          x: {
            ticks: { color: '#a89f94', maxRotation: 0, autoSkip: true, maxTicksLimit: payload.days === 7 ? 7 : 8 },
            grid: { display: false },
            border: { color: 'rgba(212, 184, 150, 0.35)' },
          },
          y: key === 'mood'
            ? { min: 1, max: 5, ticks: { stepSize: 1, color: '#a89f94' }, grid: { color: 'rgba(168, 159, 148, 0.2)' }, border: { color: 'rgba(212, 184, 150, 0.35)' } }
            : {
                beginAtZero: true,
                ticks: key === 'meals' ? { precision: 0, color: '#a89f94' } : { color: '#a89f94' },
                grid: { color: 'rgba(168, 159, 148, 0.2)' },
                border: { color: 'rgba(212, 184, 150, 0.35)' },
              },
        },
      },
    });
  }
  showMetric(activeMetric);
}

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (char) => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#39;',
  })[char]);
}

function setMapNote(message) {
  mapNote = message || '';
  const empty = document.getElementById('map-empty');
  if (!empty) return;
  empty.hidden = !mapNote;
  empty.textContent = mapNote;
}

function ensureMap() {
  const frame = document.getElementById('map');
  if (!frame || !window.L) {
    if (!window.L) showBanner('The map library did not load.');
    return null;
  }
  frame.hidden = false;
  if (!map) {
    map = L.map(frame, { scrollWheelZoom: false }).setView([20, 0], 2);
    L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
      maxZoom: 19,
      attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>',
    }).addTo(map);
    markerLayer = L.layerGroup().addTo(map);
  }
  return map;
}

function showDeviceOnMap(latitude, longitude) {
  if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) return;
  if (!ensureMap()) return;
  map.setView([latitude, longitude], 13);
  setMapNote('Centered on this device. Visited cells darken with each check-in.');
  window.setTimeout(() => map.invalidateSize(), 0);
}

function renderMap(entries) {
  const points = entries.filter(
    (entry) => entry.type === 'location'
      && Number.isFinite(entry.latitude)
      && Number.isFinite(entry.longitude)
  );
  const count = document.getElementById('map-count');
  if (!ensureMap()) return;
  if (!points.length) {
    count.textContent = '';
    mappedCount = 0;
    markerLayer.clearLayers();
    setMapNote(mapNote || 'Allow location to center this map. Visited cells darken with each check-in.');
    window.setTimeout(() => map.invalidateSize(), 0);
    return;
  }
  setMapNote('');
  count.textContent = points.length === 1 ? '1 check-in' : `${points.length} check-ins`;
  markerLayer.clearLayers();
  const cells = new Map();
  for (const point of points) {
    const south = Math.floor(point.latitude / 0.005) * 0.005;
    const west = Math.floor(point.longitude / 0.005) * 0.005;
    const key = `${south.toFixed(5)},${west.toFixed(5)}`;
    const cell = cells.get(key) || { south, west, north: south + 0.005, east: west + 0.005, count: 0 };
    cell.count += 1;
    cells.set(key, cell);
  }
  const drawn = [...cells.values()];
  const busiest = drawn.reduce((max, cell) => Math.max(max, cell.count), 1);
  const shapes = drawn.map((cell) => {
    const mix = busiest <= 1 ? 0 : (cell.count - 1) / (busiest - 1);
    const red = Math.round(212 + (18 - 212) * mix);
    const green = Math.round(184 + (17 - 184) * mix);
    const blue = Math.round(150 + (15 - 150) * mix);
    const label = cell.count === 1 ? '1 check-in in this cell' : `${cell.count} check-ins in this cell`;
    return L.rectangle([[cell.south, cell.west], [cell.north, cell.east]], {
      color: '#12110f',
      weight: 1,
      fillColor: `rgb(${red}, ${green}, ${blue})`,
      fillOpacity: 0.45 + 0.45 * mix,
    }).bindPopup(label);
  });
  shapes.forEach((shape) => shape.addTo(markerLayer));
  if (points.length !== mappedCount) {
    const bounds = L.latLngBounds(shapes.map((shape) => shape.getBounds()));
    if (drawn.length === 1) map.fitBounds(bounds.pad(0.8));
    else map.fitBounds(bounds.pad(0.25));
    mappedCount = points.length;
  }
  window.setTimeout(() => map.invalidateSize(), 0);
}

async function loadList() {
  const token = ++listToken;
  const query = searchInput.value;
  const data = await getJson(`/api/entries?q=${encodeURIComponent(query)}`);
  if (token !== listToken) return;
  renderList(data.entries, query);
}

async function loadTrends() {
  const token = ++trendsToken;
  const days = rangeDays;
  const data = await getJson(
    `/api/trends?days=${days}&tzOffsetMinutes=${new Date().getTimezoneOffset()}`
  );
  if (token !== trendsToken) return;
  renderTrends(data);
}

async function refreshAll(options = {}) {
  const token = ++dataToken;
  const listTok = ++listToken;
  const trendTok = ++trendsToken;
  const query = searchInput.value;
  const days = rangeDays;
  const [all, listed, trends] = await Promise.all([
    getJson('/api/entries'),
    getJson(`/api/entries?q=${encodeURIComponent(query)}`),
    getJson(`/api/trends?days=${days}&tzOffsetMinutes=${new Date().getTimezoneOffset()}`),
  ]);
  if (token !== dataToken) return;
  allEntries = all.entries;
  renderMap(allEntries);
  renderCorrelations();
  if (listTok === listToken) renderList(listed.entries, query);
  if (trendTok === trendsToken) renderTrends(trends);
  if (options.scroll) {
    document.getElementById('journal-heading').scrollIntoView({ block: 'nearest' });
  }
}

function clearTimer() {
  if (timer) {
    window.clearTimeout(timer);
    timer = null;
  }
}

function intervalMinutes() {
  let minutes = Math.round(Number(intervalInput.value));
  if (!Number.isFinite(minutes)) minutes = DEFAULT_MINUTES;
  minutes = Math.min(MAX_MINUTES, Math.max(MIN_MINUTES, minutes));
  if (intervalInput.value !== String(minutes)) intervalInput.value = String(minutes);
  localStorage.setItem(INTERVAL_KEY, String(minutes));
  return minutes;
}

function intervalMs() {
  return intervalMinutes() * 60 * 1000;
}

function latestLocationSavedAt() {
  return allEntries
    .filter((entry) => entry.type === 'location')
    .reduce((latest, entry) => Math.max(latest, new Date(entry.savedAt).getTime()), 0);
}

function msUntilDue() {
  const latest = latestLocationSavedAt();
  if (!latest) return 0;
  return Math.max(0, intervalMs() - (Date.now() - latest));
}

function setStatus(message) {
  trackStatus.textContent = message;
}

function nextCheckInSentence(delay) {
  const when = formatClock(new Date(Date.now() + delay));
  return `Next check-in around ${when}, every ${intervalMinutes()} minutes. Tracking stays on while this app can read the device.`;
}

function scheduleIn(ms) {
  clearTimer();
  if (!tracking) return;
  let delay = ms;
  if (!Number.isFinite(delay) || delay < 0) delay = intervalMs();
  const max = 2147483647;
  if (delay > max) {
    timer = window.setTimeout(() => {
      timer = null;
      scheduleIn(delay - max);
    }, max);
    return;
  }
  timer = window.setTimeout(() => {
    timer = null;
    void tick();
  }, delay);
}

function readPosition() {
  if (!navigator.geolocation) {
    return Promise.reject(Object.assign(new Error('Location services are not available.'), { code: 0 }));
  }
  return new Promise((resolve, reject) => {
    navigator.geolocation.getCurrentPosition(resolve, reject, {
      enableHighAccuracy: true,
      maximumAge: 0,
      timeout: 20000,
    });
  });
}

async function recordPosition() {
  const position = await readPosition();
  if (!tracking) return 'stopped';
  const { latitude, longitude, accuracy } = position.coords;
  showDeviceOnMap(latitude, longitude);
  if (!Number.isFinite(latitude) || !Number.isFinite(longitude) || !Number.isFinite(accuracy) || accuracy < 0) {
    setStatus('The device returned a reading without a usable accuracy, so it was not saved. The next try stays on the interval.');
    return 'skip';
  }
  try {
    await getJson('/api/entries', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        type: 'location',
        occurredAt: new Date(position.timestamp || Date.now()).toISOString(),
        latitude,
        longitude,
        accuracyMeters: accuracy,
        source: 'device',
      }),
    });
  } catch (error) {
    if (error.status === 429) {
      setStatus(`Tracking is on. A check-in is already recent, so this one was skipped. ${nextCheckInSentence(intervalMs())}`);
      return 'wait';
    }
    throw error;
  }
  if (!tracking) return 'stopped';
  try {
    await refreshAll();
  } catch (error) {
    if (!offlinePreview(error)) showBanner(error.message);
  }
  setStatus(`Tracking is on. A device check-in was just saved. ${nextCheckInSentence(intervalMs())}`);
  return 'saved';
}

async function tick() {
  if (!tracking || recording) return;
  recording = true;
  let outcome = 'failed';
  try {
    outcome = await recordPosition();
  } catch (error) {
    outcome = error && error.code === 1 ? 'denied' : 'failed';
    if (outcome === 'preview') {
      setStatus('Tracking is on. This preview does not store check-ins.');
      setMapNote('Centered on this device. This preview does not store check-ins.');
    } else if (outcome === 'denied') {
      setStatus('Location permission is blocked, so this check-in was not recorded. Allow location for this site. Tracking stays on and tries again on the interval.');
      setMapNote('Location access is off. Allow it to center the map. Until then the map stays on a general view.');
    } else {
      const detail = error && error.message ? error.message : 'the device location could not be read';
      setStatus(`Tracking is still on, but ${detail}. Another try waits for the interval.`);
    }
  } finally {
    recording = false;
  }
  if (!tracking || outcome === 'stopped') return;
  scheduleIn(intervalMs());
}

async function keepScreenAwake() {
  if (!navigator.wakeLock) return;
  try {
    wakeLock = await navigator.wakeLock.request('screen');
    wakeLock.addEventListener('release', () => {
      wakeLock = null;
    });
  } catch {
    // A refused screen-awake request does not pause check-ins. The interval keeps running.
  }
}

async function startTracking() {
  tracking = true;
  localStorage.setItem(TRACK_KEY, 'on');
  clearTimer();
  void keepScreenAwake();
  const wait = msUntilDue();
  if (wait > 0) {
    scheduleIn(wait);
    setStatus(`Tracking is on. ${nextCheckInSentence(wait)}`);
    return;
  }
  setStatus('Tracking is on. Asking for the device location. If you allow it once, later check-ins need no extra taps.');
  await tick();
}

function restoreInterval() {
  const raw = localStorage.getItem(INTERVAL_KEY);
  const saved = raw == null ? DEFAULT_MINUTES : Number(raw);
  intervalInput.value = String(Number.isFinite(saved) ? saved : DEFAULT_MINUTES);
  intervalMinutes();
}

function syncBristol() {
  const kind = document.getElementById('bath-kind');
  const bristol = document.getElementById('bath-bristol');
  const field = document.getElementById('bristol-field');
  const stool = kind.value === 'stool';
  field.hidden = !stool;
  bristol.disabled = !stool;
  if (!stool) bristol.value = '';
}

function bindForm(id, build) {
  const form = document.getElementById(id);
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    const button = form.querySelector('button[type="submit"]');
    const error = form.querySelector('.form-error');
    error.textContent = '';
    button.disabled = true;
    try {
      const payload = build(new FormData(form));
      await getJson('/api/entries', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });
      form.reset();
      setDefaultTimes();
      syncBristol();
      await refreshAll({ scroll: true });
    } catch (err) {
      error.textContent = offlinePreview(err)
        ? 'This preview does not store entries.'
        : (err.message || 'Could not save.');
    } finally {
      button.disabled = false;
    }
  });
}

function bindForms() {
  bindForm('meal-form', (data) => ({
    type: 'meal',
    occurredAt: fromDatetimeLocal(data.get('occurredAt')),
    description: String(data.get('description') || ''),
  }));
  bindForm('water-form', (data) => ({
    type: 'water',
    occurredAt: fromDatetimeLocal(data.get('occurredAt')),
    amountMl: Number(data.get('amountMl')),
  }));
  bindForm('bathroom-form', (data) => {
    const payload = {
      type: 'bathroom',
      occurredAt: fromDatetimeLocal(data.get('occurredAt')),
      kind: data.get('kind'),
      note: String(data.get('note') || ''),
    };
    const bristol = data.get('bristolScale');
    if (payload.kind === 'stool' && bristol) payload.bristolScale = Number(bristol);
    return payload;
  });
  bindForm('life-form', (data) => ({
    type: 'life_event',
    occurredAt: fromDatetimeLocal(data.get('occurredAt')),
    title: String(data.get('title') || ''),
    description: String(data.get('description') || ''),
  }));
  bindForm('mood-form', (data) => ({
    type: 'mood',
    occurredAt: fromDatetimeLocal(data.get('occurredAt')),
    moodScore: Number(data.get('moodScore')),
    note: String(data.get('note') || ''),
  }));
  bindForm('sleep-form', (data) => ({
    type: 'sleep',
    occurredAt: fromDatetimeLocal(data.get('occurredAt')),
    sleepHours: Number(data.get('sleepHours')),
    note: String(data.get('note') || ''),
  }));
  document.getElementById('bath-kind').addEventListener('change', syncBristol);
}

function bindSearch() {
  document.getElementById('search-form').addEventListener('submit', (event) => {
    event.preventDefault();
    loadList().catch((error) => {
      if (!offlinePreview(error)) showBanner(error.message);
    });
  });
  let searchTimer = null;
  searchInput.addEventListener('input', () => {
    window.clearTimeout(searchTimer);
    searchTimer = window.setTimeout(() => {
      loadList().catch((error) => {
        if (!offlinePreview(error)) showBanner(error.message);
      });
    }, 200);
  });
}

function bindRange() {
  document.getElementById('range').addEventListener('click', (event) => {
    const button = event.target.closest('button[data-range]');
    if (!button) return;
    const days = Number(button.dataset.range);
    if (days !== 7 && days !== 30) return;
    rangeDays = days;
    document.querySelectorAll('#range button').forEach((el) => {
      el.setAttribute('aria-pressed', el === button ? 'true' : 'false');
    });
    loadTrends().catch((error) => {
      if (!offlinePreview(error)) showBanner(error.message);
    });
  });
}

function bindTracking() {
  intervalInput.addEventListener('change', () => {
    intervalMinutes();
    if (!tracking || recording) return;
    const wait = msUntilDue();
    const delay = wait > 0 ? wait : intervalMs();
    scheduleIn(delay);
    setStatus(`Tracking is on. ${nextCheckInSentence(delay)}`);
  });
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') void keepScreenAwake();
  });
  window.addEventListener('resize', () => {
    if (map) map.invalidateSize();
  });
}

function scheduleStepReads() {
  window.clearTimeout(stepsTimer);
  stepsTimer = window.setTimeout(() => {
    stepsTimer = null;
    readStepReading().finally(scheduleStepReads);
  }, STEPS_READ_MS);
}

async function readStepReading() {
  const note = document.getElementById('steps-note');
  try {
    const reading = await getJson('/api/steps/reading');
    if (reading.saved || reading.executed || reading.available) {
      note.textContent = 'Step reading was refused. This preview does not treat that check as Apple Health.';
      return;
    }
    note.textContent = reading.reason;
  } catch (error) {
    if (!offlinePreview(error)) {
      note.textContent = 'Steps could not be checked. No step count was invented, and Apple Health was not read.';
    }
  }
}

function showView(name) {
  document.querySelectorAll('.view').forEach((el) => {
    const on = el.id === `view-${name}`;
    el.hidden = !on;
    el.classList.toggle('is-active', on);
  });
  document.querySelectorAll('.tab').forEach((el) => {
    el.setAttribute('aria-current', el.dataset.view === name ? 'page' : 'false');
  });
  if (name === 'map') {
    ensureMap();
    if (map) window.setTimeout(() => map.invalidateSize(), 60);
  }
  if (name === 'graphs') showMetric(activeMetric);
}

function showLog(kind) {
  document.querySelectorAll('.log-panel').forEach((el) => {
    el.hidden = el.dataset.panel !== kind;
  });
  showView('log');
}

function showMetric(key) {
  if (!document.querySelector(`[data-chart="${key}"]`)) return;
  activeMetric = key;
  document.querySelectorAll('[data-metric]').forEach((el) => {
    el.setAttribute('aria-pressed', el.dataset.metric === key ? 'true' : 'false');
  });
  document.querySelectorAll('.chart-card').forEach((el) => {
    el.hidden = el.dataset.chart !== key;
  });
  const chart = chartInstances[key];
  if (chart) window.setTimeout(() => chart.resize(), 40);
}

function renderCorrelations() {
  const el = document.getElementById('correlation-sentence');
  if (!el) return;
  const meals = allEntries.filter((entry) => entry.type === 'meal' && entry.description);
  const lows = allEntries.filter((entry) => entry.type === 'mood' && Number(entry.moodScore) <= 2);
  const windowMs = 4 * 60 * 60 * 1000;
  for (const mood of lows) {
    const at = Date.parse(mood.occurredAt);
    const meal = meals.find((item) => {
      const eaten = Date.parse(item.occurredAt);
      return Number.isFinite(eaten) && eaten <= at && at - eaten <= windowMs;
    });
    if (meal) {
      el.textContent = `A mood of ${mood.moodScore} lined up within 4 hours of ${meal.description}.`;
      return;
    }
  }
  el.textContent = lows.length
    ? 'Low moods are logged, and none fall within 4 hours of a meal.'
    : 'Log meals and a low mood to see whether they line up.';
}

function bindShell() {
  document.querySelector('.tabs').addEventListener('click', (event) => {
    const button = event.target.closest('[data-view]');
    if (!button) return;
    if (button.dataset.view === 'log' && !document.querySelector('.log-panel:not([hidden])')) {
      showLog('meal');
      return;
    }
    showView(button.dataset.view);
  });
  document.querySelector('.actions').addEventListener('click', (event) => {
    const button = event.target.closest('[data-open]');
    if (!button) return;
    showLog(button.dataset.open);
  });
  document.getElementById('metrics').addEventListener('click', (event) => {
    const button = event.target.closest('[data-metric]');
    if (!button) return;
    showMetric(button.dataset.metric);
  });
  showView('home');
}

async function boot() {
  if (!window.Chart || !window.L) {
    showBanner('Charts or the map did not load. Run npm install and restart the server.');
  }
  setDefaultTimes();
  syncBristol();
  restoreInterval();
  bindShell();
  bindForms();
  bindSearch();
  bindRange();
  bindTracking();
  try {
    await refreshAll();
  } catch (error) {
    if (offlinePreview(error)) showOfflinePreview();
    else showBanner(error.message);
  }
  startTracking();
  readStepReading().finally(scheduleStepReads);
}

boot();
