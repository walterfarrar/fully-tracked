'use strict';

const MIN_MINUTES = 5;
const MAX_MINUTES = 7 * 24 * 60;
const DEFAULT_MINUTES = 10;
const TRACK_KEY = 'fully-tracked-location';
const INTERVAL_KEY = 'fully-tracked-interval-min';

const TYPE_LABELS = {
  location: 'Location',
  meal: 'Meal',
  water: 'Hydration',
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
let mapFocusToken = 0;
let pendingMapPoint = null;
const MAP_FOCUS_ZOOM = 16;
const CELL_DEGREES = 0.005;

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

function formatCheckInWhen(value) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return '';
  return date.toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
}

function syncWhenDisplay(input) {
  const display = input.closest('.when-control');
  const text = display && display.querySelector('.when-display');
  if (text) text.textContent = formatCheckInWhen(input.value);
}

function setDefaultTimes() {
  const value = toDatetimeLocal(new Date());
  document.querySelectorAll('input[type="datetime-local"]').forEach((input) => {
    if (!input.value) input.value = value;
    syncWhenDisplay(input);
  });
}

function stampCheckInTimes() {
  const value = toDatetimeLocal(new Date());
  document.querySelectorAll('#checkin input[type="datetime-local"]').forEach((input) => {
    input.value = value;
    syncWhenDisplay(input);
  });
}

function bindWhenDisplays() {
  document.querySelectorAll('#checkin .when-control').forEach((control) => {
    const input = control.querySelector('input[type="datetime-local"]');
    const display = control.querySelector('.when-display');
    if (!input || !display) return;
    const refresh = () => syncWhenDisplay(input);
    input.addEventListener('input', refresh);
    input.addEventListener('change', refresh);
    display.addEventListener('click', () => {
      if (typeof input.showPicker === 'function') {
        try {
          input.showPicker();
          return;
        } catch {
          input.focus();
        }
      } else {
        input.focus();
      }
    });
  });
}

const FOODS_KEY = 'fully-tracked-foods';
const DRINKS_KEY = 'fully-tracked-drinks';
const EVENTS_KEY = 'fully-tracked-event-types';
const STARTER_FOODS = ['Eggs', 'Oatmeal', 'Rice', 'Chicken', 'Salad', 'Fruit', 'Yogurt', 'Sandwich', 'Pasta', 'Soup'];
const STARTER_DRINKS = ['Water', 'Coffee', 'Soda'];
const STARTER_EVENTS = ['Family trip', 'Birthday'];
const OZ_CHOICES = [
  { oz: 8, label: '8 oz · 1 cup' },
  { oz: 12, label: '12 oz' },
  { oz: 16, label: '16 oz · 2 cups' },
  { oz: 20, label: '20 oz' },
  { oz: 24, label: '24 oz · 3 cups' },
];
const URINE_COLORS = ['Clear', 'Pale', 'Yellow', 'Dark', 'Amber'];
const URINE_AMOUNTS = ['A little', 'Usual', 'A lot'];
const MOOD_TAGS = ['happy', 'sad', 'anxious', 'excited'];
let pickedFoods = new Set();
let pickedDrink = '';
let pickedOz = 0;
let bathKind = 'stool';
let pickedBristol = 0;
let pickedUrineColor = '';
let pickedUrineAmount = '';
let pickedEvent = '';
let pickedEmotions = new Set();
let mealNutrition = null;

function readCatalog(key, starter) {
  try {
    const parsed = JSON.parse(localStorage.getItem(key) || 'null');
    if (Array.isArray(parsed) && parsed.length) return parsed.map((item) => String(item));
  } catch {
    /* Seed the list below. */
  }
  const seeded = starter.slice();
  localStorage.setItem(key, JSON.stringify(seeded));
  return seeded;
}

function rememberCatalogItem(key, starter, name) {
  const clean = String(name || '').trim().replace(/\s+/g, ' ');
  if (!clean) return '';
  const items = readCatalog(key, starter);
  const existing = items.find((item) => item.toLowerCase() === clean.toLowerCase());
  if (existing) return existing;
  items.push(clean);
  localStorage.setItem(key, JSON.stringify(items));
  return clean;
}

function fillChoices(container, items, pressed, onPick) {
  if (!container) return;
  container.replaceChildren();
  items.forEach((item) => {
    const button = document.createElement('button');
    button.type = 'button';
    button.textContent = item.label || String(item);
    button.setAttribute('aria-pressed', pressed(item) ? 'true' : 'false');
    button.addEventListener('click', () => onPick(item));
    container.append(button);
  });
}

function renderMealFoods() {
  fillChoices(
    document.getElementById('meal-foods'),
    readCatalog(FOODS_KEY, STARTER_FOODS),
    (name) => pickedFoods.has(name),
    (name) => {
      if (pickedFoods.has(name)) pickedFoods.delete(name);
      else pickedFoods.add(name);
      renderMealFoods();
    }
  );
}

function renderDrinks() {
  fillChoices(
    document.getElementById('drink-list'),
    readCatalog(DRINKS_KEY, STARTER_DRINKS),
    (name) => name === pickedDrink,
    (name) => {
      pickedDrink = name;
      renderDrinks();
    }
  );
  fillChoices(
    document.getElementById('oz-choices'),
    OZ_CHOICES,
    (choice) => choice.oz === pickedOz,
    (choice) => {
      pickedOz = choice.oz;
      renderDrinks();
    }
  );
}

function renderEvents() {
  fillChoices(
    document.getElementById('event-types'),
    readCatalog(EVENTS_KEY, STARTER_EVENTS),
    (name) => name === pickedEvent,
    (name) => {
      pickedEvent = name;
      renderEvents();
    }
  );
}

function renderBathChoices() {
  document.querySelectorAll('#bath-kind-toggle button').forEach((button) => {
    button.setAttribute('aria-pressed', button.dataset.kind === bathKind ? 'true' : 'false');
  });
  const bristol = document.getElementById('bristol-options');
  const urine = document.getElementById('urine-options');
  if (bristol) bristol.hidden = bathKind !== 'stool';
  if (urine) urine.hidden = bathKind !== 'urine';
  fillChoices(
    document.getElementById('bristol-choices'),
    [1, 2, 3, 4, 5, 6, 7],
    (value) => value === pickedBristol,
    (value) => {
      pickedBristol = value;
      renderBathChoices();
    }
  );
  fillChoices(
    document.getElementById('urine-colors'),
    URINE_COLORS,
    (name) => name === pickedUrineColor,
    (name) => {
      pickedUrineColor = name;
      renderBathChoices();
    }
  );
  fillChoices(
    document.getElementById('urine-amounts'),
    URINE_AMOUNTS,
    (name) => name === pickedUrineAmount,
    (name) => {
      pickedUrineAmount = name;
      renderBathChoices();
    }
  );
}

function syncMoodFace() {
  const input = document.getElementById('mood-score');
  const mouth = document.getElementById('mood-mouth');
  const score = input ? Number(input.value) : 6;
  if (!mouth) return;
  if (score <= 2) mouth.setAttribute('d', 'M8 16c1.2-1.6 2.4-2.2 4-2.2s2.8.6 4 2.2');
  else if (score <= 4) mouth.setAttribute('d', 'M8.5 15.5c1.1-1 2.2-1.4 3.5-1.4s2.4.4 3.5 1.4');
  else if (score <= 6) mouth.setAttribute('d', 'M8.5 15h7');
  else if (score <= 8) mouth.setAttribute('d', 'M8.5 14.2c1.1 1.1 2.3 1.6 3.5 1.6s2.4-.5 3.5-1.6');
  else mouth.setAttribute('d', 'M8 13.5c1.2 2 2.6 3 4 3s2.8-1 4-3');
}

function renderMoodTags() {
  fillChoices(
    document.getElementById('mood-tags'),
    MOOD_TAGS,
    (name) => pickedEmotions.has(name),
    (name) => {
      if (pickedEmotions.has(name)) pickedEmotions.delete(name);
      else pickedEmotions.add(name);
      renderMoodTags();
    }
  );
  syncMoodFace();
}

function renderCheckInChoices() {
  renderMealFoods();
  renderDrinks();
  renderEvents();
  renderBathChoices();
  renderMoodTags();
}

function resetCheckInState() {
  pickedFoods = new Set();
  pickedDrink = '';
  pickedOz = 0;
  bathKind = 'stool';
  pickedBristol = 0;
  pickedUrineColor = '';
  pickedUrineAmount = '';
  pickedEvent = '';
  pickedEmotions = new Set();
  mealNutrition = null;
  const amount = document.getElementById('meal-amount');
  if (amount) amount.value = '';
  const foodNew = document.getElementById('meal-food-new');
  if (foodNew) foodNew.value = '';
  const drinkNew = document.getElementById('drink-new');
  if (drinkNew) drinkNew.value = '';
  const eventNew = document.getElementById('event-new');
  if (eventNew) eventNew.value = '';
  const lifeDesc = document.getElementById('life-description');
  if (lifeDesc) lifeDesc.value = '';
  const bathNote = document.getElementById('bath-note');
  if (bathNote) bathNote.value = '';
  const mood = document.getElementById('mood-score');
  if (mood) mood.value = '6';
  const box = document.getElementById('meal-nutrition');
  if (box) {
    box.hidden = true;
    box.textContent = '';
  }
  renderCheckInChoices();
}

function firstNumber(line) {
  const match = String(line).match(/([0-9]+(?:\.[0-9]+)?)/);
  return match ? match[1] : '';
}

function servingSizeFrom(lines, index) {
  const line = String(lines[index]);
  const lowered = line.toLowerCase();
  const at = lowered.indexOf('serving size');
  if (at < 0) return '';
  const rest = line.slice(at + 'serving size'.length).replace(/^[\s:.-]+/, '').trim();
  if (rest) return rest;
  const next = lines[index + 1];
  if (!next) return '';
  const candidate = String(next).trim();
  const lower = candidate.toLowerCase();
  if (lower.includes('serving') || lower.includes('amount')) return '';
  return candidate;
}

function parseNutritionLines(lines) {
  const draft = {
    servingSize: '',
    calories: '',
    totalFat: '',
    saturatedFat: '',
    cholesterol: '',
    sodium: '',
    carbohydrates: '',
    fiber: '',
    sugar: '',
    protein: '',
    message: '',
    filledAny: false,
  };
  const source = Array.isArray(lines) ? lines.slice() : [];
  const index = source.findIndex((line) => String(line).toLowerCase().includes('serving size'));
  if (index >= 0) {
    draft.servingSize = servingSizeFrom(source, index);
    source.splice(index, 1);
  }
  const rules = [
    ['saturated fat', 'saturatedFat'],
    ['cholesterol', 'cholesterol'],
    ['sodium', 'sodium'],
    ['dietary fiber', 'fiber'],
    ['total fiber', 'fiber'],
    ['fiber', 'fiber'],
    ['total sugars', 'sugar'],
    ['sugars', 'sugar'],
    ['sugar', 'sugar'],
    ['total carbohydrate', 'carbohydrates'],
    ['carbohydrate', 'carbohydrates'],
    ['protein', 'protein'],
    ['total fat', 'totalFat'],
    ['calories', 'calories'],
  ];
  source.forEach((line) => {
    const lowered = String(line).toLowerCase();
    if (lowered.includes('calories from fat')) return;
    for (let i = 0; i < rules.length; i += 1) {
      const name = rules[i][0];
      const key = rules[i][1];
      if (lowered.includes(name) && !draft[key]) {
        const number = firstNumber(line);
        if (number) draft[key] = number;
        break;
      }
    }
  });
  draft.filledAny = [
    draft.servingSize, draft.calories, draft.totalFat, draft.saturatedFat, draft.cholesterol,
    draft.sodium, draft.carbohydrates, draft.fiber, draft.sugar, draft.protein,
  ].some((value) => String(value).trim());
  draft.message = draft.filledAny
    ? 'Label facts are ready to save with how much you had. The photo was not saved.'
    : 'No nutrition facts were read. Nothing was filled in. The photo was not saved.';
  return draft;
}

function nutritionPayload(draft) {
  if (!draft || !draft.filledAny) return {};
  const payload = {};
  if (draft.servingSize) payload.servingSize = draft.servingSize;
  ['calories', 'totalFat', 'saturatedFat', 'cholesterol', 'sodium', 'carbohydrates', 'fiber', 'sugar', 'protein'].forEach((key) => {
    if (draft[key] === '' || draft[key] == null) return;
    const value = Number(draft[key]);
    if (Number.isFinite(value)) payload[key] = value;
  });
  return payload;
}

function showNutritionMessage(message) {
  const box = document.getElementById('meal-nutrition');
  if (!box) return;
  box.hidden = !message;
  box.textContent = message || '';
}

async function readNutritionFile(file) {
  if (!file) return;
  let bitmap = null;
  try {
    bitmap = await createImageBitmap(file);
    let lines = [];
    if (typeof TextDetector === 'function') {
      const detector = new TextDetector();
      const found = await detector.detect(bitmap);
      lines = found.map((item) => item.rawValue).filter(Boolean);
    } else {
      const mod = await import('https://cdn.jsdelivr.net/npm/tesseract.js@5.1.1/dist/tesseract.esm.min.js');
      const worker = await mod.createWorker('eng');
      try {
        const result = await worker.recognize(bitmap);
        lines = String((result.data && result.data.text) || '').split(/\n+/);
      } finally {
        await worker.terminate();
      }
    }
    const draft = parseNutritionLines(lines);
    mealNutrition = draft.filledAny ? draft : null;
    showNutritionMessage(draft.message);
  } catch {
    mealNutrition = null;
    showNutritionMessage('No nutrition facts were read. Nothing was filled in. The photo was not saved.');
  } finally {
    if (bitmap && bitmap.close) bitmap.close();
  }
}

function addTypedFood() {
  const input = document.getElementById('meal-food-new');
  const saved = rememberCatalogItem(FOODS_KEY, STARTER_FOODS, input && input.value);
  if (!saved) return;
  pickedFoods.add(saved);
  input.value = '';
  renderMealFoods();
}

function addTypedDrink() {
  const input = document.getElementById('drink-new');
  const saved = rememberCatalogItem(DRINKS_KEY, STARTER_DRINKS, input && input.value);
  if (!saved) return;
  pickedDrink = saved;
  input.value = '';
  renderDrinks();
}

function addTypedEvent() {
  const input = document.getElementById('event-new');
  const saved = rememberCatalogItem(EVENTS_KEY, STARTER_EVENTS, input && input.value);
  if (!saved) return '';
  pickedEvent = saved;
  input.value = '';
  renderEvents();
  return saved;
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
  const manualPing = Boolean(body.manual);
  if (body.type === 'location' && !manualPing) {
    const latest = entries
      .filter((entry) => entry.type === 'location')
      .reduce((max, entry) => Math.max(max, new Date(entry.savedAt).getTime()), 0);
    if (latest && Date.now() - latest < intervalMs()) {
      const error = new Error('A check-in is already recent.');
      error.status = 429;
      throw error;
    }
  }
  const stored = { ...body };
  delete stored.manual;
  const entry = {
    id: typeof crypto !== 'undefined' && crypto.randomUUID ? crypto.randomUUID() : String(Date.now()),
    savedAt: new Date().toISOString(),
    ...stored,
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
  if (entry.type === 'meal') {
    const foods = Array.isArray(entry.foods) && entry.foods.length ? entry.foods.join(', ') : entry.description;
    const lines = foods ? [foods] : [];
    if (entry.amountHad) lines.push(entry.amountHad);
    if (entry.calories != null && entry.calories !== '') lines.push(`${entry.calories} kcal`);
    return lines;
  }
  if (entry.type === 'water') {
    const name = entry.drinkName || 'Water';
    if (entry.amountOz != null) return [`${name} · ${formatNum(entry.amountOz)} oz`];
    return [`${name} · ${formatNum(entry.amountMl)} ml`];
  }
  if (entry.type === 'bathroom') {
    const bits = [entry.kind === 'stool' ? 'Stool' : 'Urine'];
    if (entry.kind === 'stool' && entry.bristolScale != null) bits.push(`Bristol ${entry.bristolScale}`);
    if (entry.kind === 'urine') {
      if (entry.urineColor) bits.push(entry.urineColor);
      if (entry.urineAmount) bits.push(entry.urineAmount);
    }
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
    const lines = [`${entry.moodScore} / 10`];
    if (Array.isArray(entry.emotions) && entry.emotions.length) lines.push(entry.emotions.join(', '));
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
      : 'Nothing here yet. Location check-ins appear when tracking is on. Meals, hydration, bathroom, life events, mood, and sleep can be added by hand.';
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
    if (entry.type === 'location' && Number.isFinite(entry.latitude) && Number.isFinite(entry.longitude)) {
      article.tabIndex = 0;
      article.setAttribute('role', 'button');
      const openOnMap = () => focusMapOnEntry(entry.latitude, entry.longitude);
      article.addEventListener('click', openOnMap);
      article.addEventListener('keydown', (event) => {
        if (event.key !== 'Enter' && event.key !== ' ') return;
        event.preventDefault();
        openOnMap();
      });
    }
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

function locationPoints(entries) {
  return (entries || []).filter(
    (entry) => entry.type === 'location'
      && Number.isFinite(entry.latitude)
      && Number.isFinite(entry.longitude)
  );
}

function heatCellsFor(points) {
  const cells = new Map();
  for (const point of points) {
    const south = Math.floor(point.latitude / CELL_DEGREES) * CELL_DEGREES;
    const west = Math.floor(point.longitude / CELL_DEGREES) * CELL_DEGREES;
    const key = `${south.toFixed(5)},${west.toFixed(5)}`;
    const cell = cells.get(key) || {
      south,
      west,
      north: south + CELL_DEGREES,
      east: west + CELL_DEGREES,
      count: 0,
    };
    cell.count += 1;
    cells.set(key, cell);
  }
  return [...cells.values()];
}

function frameSavedCheckIns() {
  if (!map) return;
  const points = locationPoints(allEntries);
  const cells = heatCellsFor(points);
  if (!points.length || !cells.length) return;
  if (points.length === 1) {
    map.setView([points[0].latitude, points[0].longitude], MAP_FOCUS_ZOOM);
    return;
  }
  if (cells.length === 1) {
    const cell = cells[0];
    map.setView([(cell.south + cell.north) / 2, (cell.west + cell.east) / 2], MAP_FOCUS_ZOOM);
    return;
  }
  const bounds = L.latLngBounds([]);
  cells.forEach((cell) => {
    bounds.extend([cell.south, cell.west]);
    bounds.extend([cell.north, cell.east]);
  });
  map.fitBounds(bounds.pad(0.25));
}

function focusMapOnEntry(latitude, longitude) {
  if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) return;
  mapFocusToken += 1;
  pendingMapPoint = { latitude, longitude };
  showView('map');
}

function mapTabOpen() {
  const view = document.getElementById('view-map');
  return Boolean(view && !view.hidden);
}

async function focusMapOnOpen() {
  const token = ++mapFocusToken;
  if (!ensureMap()) return;
  map.invalidateSize();
  frameSavedCheckIns();
  try {
    const position = await readPosition();
    if (token !== mapFocusToken || !map || !mapTabOpen()) return;
    const { latitude, longitude } = position.coords;
    if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) {
      frameSavedCheckIns();
      return;
    }
    map.setView([latitude, longitude], MAP_FOCUS_ZOOM);
    if (!locationPoints(allEntries).length) {
      setMapNote('Centered on this device. Visited cells darken with each check-in.');
    }
    window.setTimeout(() => map.invalidateSize(), 0);
  } catch {
    if (token !== mapFocusToken || !map || !mapTabOpen()) return;
    map.invalidateSize();
    frameSavedCheckIns();
  }
}

function heatFill(count) {
  const mix = Math.min(1, Math.max(0, (count - 1) / 99));
  const red = Math.round(214 + (192 - 214) * mix);
  const green = Math.round(236 + (48 - 236) * mix);
  const blue = Math.round(196 + (42 - 196) * mix);
  return `rgb(${red}, ${green}, ${blue})`;
}

function renderMap(entries) {
  const points = locationPoints(entries);
  const count = document.getElementById('map-count');
  if (!ensureMap()) return;
  if (!points.length) {
    count.textContent = '';
    markerLayer.clearLayers();
    setMapNote(mapNote || 'Allow location to center this map. Visited cells darken with each check-in.');
    window.setTimeout(() => map.invalidateSize(), 0);
    return;
  }
  setMapNote('');
  count.textContent = points.length === 1 ? '1 check-in' : `${points.length} check-ins`;
  markerLayer.clearLayers();
  const drawn = heatCellsFor(points);
  const shapes = drawn.map((cell) => {
    const fill = heatFill(cell.count);
    const label = cell.count === 1 ? '1 check-in in this cell' : `${cell.count} check-ins in this cell`;
    return L.rectangle([[cell.south, cell.west], [cell.north, cell.east]], {
      color: '#243028',
      weight: 1.5,
      fillColor: fill,
      fillOpacity: 0.82,
    }).bindPopup(label);
  });
  shapes.forEach((shape) => shape.addTo(markerLayer));
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

async function pingLocation() {
  const button = document.querySelector('[data-open="location"]');
  const note = document.getElementById('home-note');
  if (button) button.disabled = true;
  try {
    const position = await readPosition();
    const { latitude, longitude, accuracy } = position.coords;
    if (!Number.isFinite(latitude) || !Number.isFinite(longitude) || !Number.isFinite(accuracy) || accuracy < 0) {
      showBanner('The device returned a reading without a usable accuracy, so it was not saved.');
      return;
    }
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
        manual: true,
      }),
    });
    showBanner('');
    if (note) {
      note.hidden = false;
      note.textContent = 'Location recorded.';
    }
    try {
      await refreshAll();
    } catch (error) {
      if (!offlinePreview(error)) showBanner(error.message);
    }
  } catch (error) {
    if (note) note.hidden = true;
    const fromDevice = error && (error.code === 1 || error.code === 2 || error.code === 3);
    showBanner(fromDevice ? 'Location was not recorded.' : (error.message || 'Location was not recorded.'));
  } finally {
    if (button) button.disabled = false;
  }
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
  renderBathChoices();
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
      resetCheckInState();
      closeCheckIn();
      await refreshAll();
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
  bindForm('meal-form', (data) => {
    const foods = [...pickedFoods];
    const amountHad = document.getElementById('meal-amount').value.trim();
    if (!foods.length && !(mealNutrition && mealNutrition.filledAny)) throw new Error('Choose a food.');
    if (mealNutrition && mealNutrition.filledAny && !amountHad) throw new Error('Enter how much you had.');
    return {
      type: 'meal',
      occurredAt: fromDatetimeLocal(data.get('occurredAt')),
      description: foods.join(', '),
      foods,
      amountHad: amountHad || undefined,
      ...nutritionPayload(mealNutrition),
    };
  });
  bindForm('water-form', (data) => {
    if (!pickedDrink) throw new Error('Choose a drink.');
    if (!pickedOz) throw new Error('Choose an amount.');
    return {
      type: 'water',
      occurredAt: fromDatetimeLocal(data.get('occurredAt')),
      drinkName: pickedDrink,
      amountOz: pickedOz,
    };
  });
  bindForm('bathroom-form', (data) => {
    const payload = {
      type: 'bathroom',
      occurredAt: fromDatetimeLocal(data.get('occurredAt')),
      kind: bathKind,
      note: String(data.get('note') || ''),
    };
    if (bathKind === 'stool') {
      if (!pickedBristol) throw new Error('Choose a Bristol type.');
      payload.bristolScale = pickedBristol;
    } else {
      if (!pickedUrineColor || !pickedUrineAmount) throw new Error('Choose a urine color and amount.');
      payload.urineColor = pickedUrineColor;
      payload.urineAmount = pickedUrineAmount;
    }
    return payload;
  });
  bindForm('life-form', (data) => {
    const typed = addTypedEvent();
    const title = pickedEvent || typed;
    if (!title) throw new Error('Choose a type.');
    const description = String(data.get('description') || '').trim();
    return {
      type: 'life_event',
      occurredAt: fromDatetimeLocal(data.get('occurredAt')),
      title,
      description,
    };
  });
  bindForm('mood-form', (data) => {
    const moodScore = Number(data.get('moodScore'));
    if (!Number.isInteger(moodScore) || moodScore < 1 || moodScore > 10) throw new Error('Choose a score from 1 to 10.');
    return {
      type: 'mood',
      occurredAt: fromDatetimeLocal(data.get('occurredAt')),
      moodScore,
      emotions: [...pickedEmotions],
    };
  });
  bindForm('sleep-form', (data) => ({
    type: 'sleep',
    occurredAt: fromDatetimeLocal(data.get('occurredAt')),
    sleepHours: Number(data.get('sleepHours')),
    note: String(data.get('note') || ''),
  }));
  document.getElementById('bath-kind-toggle').addEventListener('click', (event) => {
    const button = event.target.closest('button[data-kind]');
    if (!button) return;
    bathKind = button.dataset.kind;
    renderBathChoices();
  });
  document.getElementById('meal-food-add').addEventListener('click', addTypedFood);
  document.getElementById('meal-food-new').addEventListener('keydown', (event) => {
    if (event.key !== 'Enter') return;
    event.preventDefault();
    addTypedFood();
  });
  document.getElementById('drink-add').addEventListener('click', addTypedDrink);
  document.getElementById('drink-new').addEventListener('keydown', (event) => {
    if (event.key !== 'Enter') return;
    event.preventDefault();
    addTypedDrink();
  });
  document.getElementById('event-add').addEventListener('click', addTypedEvent);
  document.getElementById('event-new').addEventListener('keydown', (event) => {
    if (event.key !== 'Enter') return;
    event.preventDefault();
    addTypedEvent();
  });
  document.getElementById('mood-score').addEventListener('input', syncMoodFace);
  document.getElementById('meal-take').addEventListener('click', () => {
    document.getElementById('meal-camera').click();
  });
  document.getElementById('meal-choose').addEventListener('click', () => {
    document.getElementById('meal-library').click();
  });
  const onPhoto = (event) => {
    const file = event.target.files && event.target.files[0];
    event.target.value = '';
    if (file) void readNutritionFile(file);
  };
  document.getElementById('meal-camera').addEventListener('change', onPhoto);
  document.getElementById('meal-library').addEventListener('change', onPhoto);
  renderCheckInChoices();
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

function openCheckIn(kind) {
  const layer = document.getElementById('checkin');
  if (!layer) return;
  document.querySelectorAll('.log-panel').forEach((el) => {
    el.hidden = el.dataset.panel !== kind;
  });
  const heading = document.getElementById('checkin-heading');
  const source = document.querySelector(`.actions button[data-open="${kind}"]`);
  const label = source && source.querySelector('span');
  if (heading && label) heading.textContent = label.textContent;
  layer.hidden = false;
  stampCheckInTimes();
  if (kind === 'bathroom') syncBristol();
}

function closeCheckIn() {
  const layer = document.getElementById('checkin');
  if (layer) layer.hidden = true;
}

function showView(name) {
  closeCheckIn();
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
    const point = pendingMapPoint;
    pendingMapPoint = null;
    window.setTimeout(() => {
      if (!mapTabOpen() || !map) return;
      map.invalidateSize();
      if (point) {
        map.setView([point.latitude, point.longitude], MAP_FOCUS_ZOOM);
        return;
      }
      void focusMapOnOpen();
    }, 60);
  }
  if (name === 'graphs') showMetric(activeMetric);
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
  const meals = allEntries.filter((entry) => entry.type === 'meal' && (entry.description || (Array.isArray(entry.foods) && entry.foods.length)));
  const lows = allEntries.filter((entry) => entry.type === 'mood' && Number(entry.moodScore) <= 4);
  const windowMs = 4 * 60 * 60 * 1000;
  for (const mood of lows) {
    const at = Date.parse(mood.occurredAt);
    const meal = meals.find((item) => {
      const eaten = Date.parse(item.occurredAt);
      return Number.isFinite(eaten) && eaten <= at && at - eaten <= windowMs;
    });
    if (meal) {
      const mealName = meal.description || (Array.isArray(meal.foods) ? meal.foods.join(', ') : 'a meal');
      el.textContent = `A mood of ${mood.moodScore} lined up within 4 hours of ${mealName}.`;
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
    showView(button.dataset.view);
  });
  document.querySelector('.actions').addEventListener('click', (event) => {
    const button = event.target.closest('[data-open]');
    if (!button) return;
    if (button.dataset.open === 'location') {
      void pingLocation();
      return;
    }
    openCheckIn(button.dataset.open);
  });
  document.getElementById('checkin-close').addEventListener('click', closeCheckIn);
  bindWhenDisplays();
  document.addEventListener('keydown', (event) => {
    if (event.key !== 'Escape') return;
    const active = document.activeElement;
    if (active && active.type === 'datetime-local') return;
    const layer = document.getElementById('checkin');
    if (layer && !layer.hidden) closeCheckIn();
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
