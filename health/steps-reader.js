'use strict';

// Contract for a future iOS reader. This file does not call HealthKit.
// On this computer the read always reports that no query ran and no totals exist.

const CONTRACT = {
  platform: 'ios',
  capability: 'HealthKit',
  entitlement: 'com.apple.developer.healthkit',
  usageDescriptionKey: 'NSHealthShareUsageDescription',
  shareType: 'HKQuantityTypeIdentifierStepCount',
  access: 'read',
  query: 'HKStatisticsCollectionQuery',
  statistic: 'cumulativeSum',
  interval: 'day',
  source: 'apple-health',
  schedule: 'once when the app opens, then about every 30 minutes while it is open',
  backgroundDelivery: false,
  writeAccess: false,
};

const REASON = 'Apple Health is not available in this preview. No step total was saved, and none is invented here. A real daily total appears only after the iOS app, with read access allowed, stores it.';

function readDailyStepTotals() {
  return {
    available: false,
    executed: false,
    source: null,
    days: [],
    reason: REASON,
    contract: CONTRACT,
  };
}

module.exports = {
  CONTRACT,
  REASON,
  READ_INTERVAL_MS: 30 * 60 * 1000,
  readDailyStepTotals,
};
