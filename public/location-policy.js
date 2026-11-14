'use strict';

// Used by the map, browser check-in loop, and local server.
(() => {
  const CELL_DEGREES = 0.00125;
  const SAME_CELL_SAVE_MS = 60 * 60 * 1000;

  function gridCell(latitude, longitude) {
    const south = Math.floor(latitude / CELL_DEGREES) * CELL_DEGREES;
    const west = Math.floor(longitude / CELL_DEGREES) * CELL_DEGREES;
    return {
      south, west,
      north: south + CELL_DEGREES,
      east: west + CELL_DEGREES,
      key: `${south.toFixed(5)},${west.toFixed(5)}`,
    };
  }

  function shouldSaveAutomatic(current, previous, now = Date.now()) {
    if (!previous || !Number.isFinite(previous.latitude) || !Number.isFinite(previous.longitude)) return true;
    const savedAt = new Date(previous.savedAt).getTime();
    if (!Number.isFinite(savedAt)) return true;
    const cell = gridCell(current.latitude, current.longitude);
    const previousCell = gridCell(previous.latitude, previous.longitude);
    return cell.south !== previousCell.south || cell.west !== previousCell.west
      || now - savedAt >= SAME_CELL_SAVE_MS;
  }

  function checkDelay(now, interval, lastCheckedAt, lastSavedAt) {
    const anchors = [lastCheckedAt, lastSavedAt].filter(Number.isFinite);
    if (!anchors.length) return 0;
    return Math.max(0, interval - (now - Math.max(...anchors)));
  }

  const policy = { CELL_DEGREES, SAME_CELL_SAVE_MS, gridCell, shouldSaveAutomatic, checkDelay };
  if (typeof module !== 'undefined' && module.exports) module.exports = policy;
  else globalThis.LocationCheckIns = policy;
})();
