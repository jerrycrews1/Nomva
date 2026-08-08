"use strict";

const ISO_DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/;
const MIN_WEIGHT_GRAMS = 18_000;
const MAX_WEIGHT_GRAMS = 545_000;

function shiftedDate(dateString, dayOffset) {
  const date = new Date(`${dateString}T00:00:00.000Z`);
  date.setUTCDate(date.getUTCDate() + dayOffset);
  return date.toISOString().slice(0, 10);
}

function validDateOrToday(value) {
  if (typeof value === "string" && ISO_DATE_PATTERN.test(value)) {
    const parsed = new Date(`${value}T00:00:00.000Z`);
    if (!Number.isNaN(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value) {
      return value;
    }
  }
  return new Date().toISOString().slice(0, 10);
}

function computeGarminAverages(
  summaries,
  { windowDays = 28, currentLocalDate } = {}
) {
  const safeWindowDays = Math.max(1, Math.min(90, Number(windowDays) || 28));
  const today = validDateOrToday(currentLocalDate);
  const windowStart = shiftedDate(today, -safeWindowDays);

  const completedDays = (Array.isArray(summaries) ? summaries : [])
    .filter((summary) => (
      summary &&
      typeof summary.date === "string" &&
      summary.date >= windowStart &&
      summary.date < today &&
      Number.isFinite(Number(summary.activeCalories)) &&
      Number(summary.activeCalories) >= 0
    ))
    .sort((a, b) => b.date.localeCompare(a.date));

  if (!completedDays.length) {
    return {
      averageActiveCalories: null,
      sampledDays: 0,
      windowDays: safeWindowDays,
      averageThroughDate: null,
    };
  }

  const total = completedDays.reduce(
    (sum, summary) => sum + Number(summary.activeCalories),
    0
  );

  return {
    averageActiveCalories: total / completedDays.length,
    sampledDays: completedDays.length,
    windowDays: safeWindowDays,
    averageThroughDate: completedDays[0].date,
  };
}

function firstFiniteNumber(...values) {
  for (const value of values) {
    const parsed = Number(value);
    if (value !== null && value !== undefined && value !== "" && Number.isFinite(parsed)) {
      return parsed;
    }
  }
  return null;
}

function garminMeasurementDate(record) {
  const epochSeconds = firstFiniteNumber(
    record?.measurementTimeInSeconds,
    record?.startTimeInSeconds,
    record?.timestampInSeconds,
    record?.measurementTimestampInSeconds
  );
  if (epochSeconds && epochSeconds > 0) {
    return new Date(epochSeconds * 1000);
  }

  const epochMilliseconds = firstFiniteNumber(
    record?.measurementTimeInMillis,
    record?.startTimeInMillis,
    record?.timestampInMillis,
    record?.startTimeGMT
  );
  if (epochMilliseconds && epochMilliseconds > 0) {
    return new Date(epochMilliseconds);
  }

  const date = record?.calendarDate || record?.summaryDate || record?.date;
  if (typeof date === "string" && ISO_DATE_PATTERN.test(date)) {
    return new Date(`${date}T12:00:00.000Z`);
  }
  return null;
}

function normalizedGarminWeight(record) {
  if (!record || typeof record !== "object" || Array.isArray(record)) {
    return null;
  }

  const explicitGrams = firstFiniteNumber(
    record.weightInGrams,
    record.weightGrams,
    record.weight_in_grams
  );
  const kilograms = firstFiniteNumber(
    record.weightInKilograms,
    record.weightKg,
    record.weight_kg
  );
  const pounds = firstFiniteNumber(record.weightInPounds, record.weightLbs);
  const grams = explicitGrams ??
    (kilograms === null ? null : kilograms * 1_000) ??
    (pounds === null ? null : pounds * 453.59237);
  const measuredAt = garminMeasurementDate(record);

  if (!measuredAt || Number.isNaN(measuredAt.getTime()) || grams === null ||
      grams < MIN_WEIGHT_GRAMS || grams > MAX_WEIGHT_GRAMS) {
    return null;
  }

  const measuredAtISO = measuredAt.toISOString();
  const sourceId = record.summaryId || record.measurementId || record.id ||
    `${measuredAtISO}:${Math.round(grams)}`;

  return {
    id: String(sourceId),
    measuredAt: measuredAtISO,
    weightKg: grams / 1_000,
  };
}

function buildGarminUploadWindows({ lookbackDays, nowSeconds = Math.floor(Date.now() / 1000) }) {
  const safeDays = Math.max(1, Math.min(365, Number.parseInt(lookbackDays, 10) || 1));
  // Garmin accepts at most 86,400 inclusive seconds per request. Adding one
  // keeps an N-day import to exactly N adjacent requests with no overlap.
  const earliest = nowSeconds - (safeDays * 86_400) + 1;
  const windows = [];
  let end = nowSeconds;

  while (end > earliest) {
    const start = Math.max(earliest, end - 86_399);
    windows.push({ start, end });
    end = start - 1;
  }
  return windows;
}

module.exports = {
  buildGarminUploadWindows,
  computeGarminAverages,
  normalizedGarminWeight,
};
