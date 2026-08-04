"use strict";

const ISO_DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/;

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

module.exports = {
  computeGarminAverages,
};
