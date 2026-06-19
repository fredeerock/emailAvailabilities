const STORAGE_KEY = "availability-composer-settings-v4";
// Free CORS proxy — no account required. Only the iCal URL is sent through it.
const CORS_PROXY = "https://corsproxy.io/?url=";

const el = {
  icalUrl: document.getElementById("icalUrl"),
  saveUrlBtn: document.getElementById("saveUrlBtn"),
  clearUrlBtn: document.getElementById("clearUrlBtn"),
  calBadge: document.getElementById("calBadge"),
  durationMin: document.getElementById("durationMin"),
  spanDays: document.getElementById("spanDays"),
  maxOptions: document.getElementById("maxOptions"),
  dayStart: document.getElementById("dayStart"),
  dayEnd: document.getElementById("dayEnd"),
  slotStep: document.getElementById("slotStep"),
  leadHours: document.getElementById("leadHours"),
  weekdaysOnly: document.getElementById("weekdaysOnly"),
  generateBtn: document.getElementById("generateBtn"),
  statusText: document.getElementById("statusText"),
  resultText: document.getElementById("resultText"),
  resultList: document.getElementById("resultList"),
  copyBtn: document.getElementById("copyBtn"),
};

init();

function init() {
  applySavedSettings();
  el.saveUrlBtn.addEventListener("click", onSaveUrl);
  el.clearUrlBtn.addEventListener("click", onClearUrl);
  el.generateBtn.addEventListener("click", onGenerate);
  el.copyBtn.addEventListener("click", onCopy);

  const settingInputs = [
    el.durationMin, el.spanDays, el.maxOptions,
    el.dayStart, el.dayEnd, el.slotStep, el.leadHours, el.weekdaysOnly,
  ];
  for (const input of settingInputs) {
    input.addEventListener("change", saveSettings);
  }
}

function applySavedSettings() {
  const defaults = {
    icalUrl: "",
    durationMin: "60",
    spanDays: "7",
    maxOptions: "5",
    dayStart: "09:00",
    dayEnd: "17:00",
    slotStep: "30",
    leadHours: "2",
    weekdaysOnly: true,
  };
  let saved = {};
  try {
    saved = JSON.parse(localStorage.getItem(STORAGE_KEY) || "{}");
  } catch {
    saved = {};
  }
  el.icalUrl.value = saved.icalUrl ?? defaults.icalUrl;
  el.durationMin.value = String(saved.durationMin ?? defaults.durationMin);
  el.spanDays.value = String(saved.spanDays ?? defaults.spanDays);
  el.maxOptions.value = String(saved.maxOptions ?? defaults.maxOptions);
  el.dayStart.value = saved.dayStart ?? defaults.dayStart;
  el.dayEnd.value = saved.dayEnd ?? defaults.dayEnd;
  el.slotStep.value = String(saved.slotStep ?? defaults.slotStep);
  el.leadHours.value = String(saved.leadHours ?? defaults.leadHours);
  el.weekdaysOnly.checked = saved.weekdaysOnly ?? defaults.weekdaysOnly;
  updateCalBadge();
}

function saveSettings() {
  localStorage.setItem(STORAGE_KEY, JSON.stringify({
    icalUrl: el.icalUrl.value.trim(),
    durationMin: Number(el.durationMin.value),
    spanDays: Number(el.spanDays.value),
    maxOptions: Number(el.maxOptions.value),
    dayStart: el.dayStart.value,
    dayEnd: el.dayEnd.value,
    slotStep: Number(el.slotStep.value),
    leadHours: Number(el.leadHours.value),
    weekdaysOnly: el.weekdaysOnly.checked,
  }));
}

function onSaveUrl() {
  const url = el.icalUrl.value.trim();
  if (!url) {
    updateStatus("Paste your secret iCal URL first.", "warn");
    return;
  }
  if (!url.includes("calendar.google.com") && !url.endsWith(".ics")) {
    updateStatus("That doesn't look like a Google Calendar iCal URL. Check and try again.", "warn");
    return;
  }
  saveSettings();
  updateCalBadge();
  updateStatus("Calendar link saved. Click Find my times.", "ok");
}

function onClearUrl() {
  el.icalUrl.value = "";
  saveSettings();
  updateCalBadge();
  updateStatus("Calendar link cleared.");
}

function updateCalBadge() {
  const hasUrl = Boolean(el.icalUrl.value.trim());
  el.calBadge.textContent = hasUrl ? "Link saved" : "No link saved";
  el.calBadge.classList.toggle("ok", hasUrl);
  el.generateBtn.disabled = !hasUrl;
}

function updateStatus(text, mode = "") {
  el.statusText.textContent = text;
  el.statusText.classList.remove("ok", "warn");
  if (mode) el.statusText.classList.add(mode);
}

async function onGenerate() {
  el.copyBtn.disabled = true;
  el.resultList.innerHTML = "";
  el.resultText.value = "";

  try {
    const settings = readSettings();
    validateSettings(settings);
    saveSettings();

    const icalUrl = el.icalUrl.value.trim();
    if (!icalUrl) throw new Error("Paste and save your Google Calendar secret iCal URL first.");

    updateStatus("Fetching your calendar...");

    const icsText = await fetchIcalViaProxy(icalUrl);
    const { start, end } = buildRange(settings);
    const busyBlocks = parseIcsBusyBlocks(icsText, start, end);

    updateStatus("Building suggestions...");

    const candidates = buildCandidateSlots(start, end, busyBlocks, settings);
    if (candidates.length === 0) {
      updateStatus("No free slots in that range. Widen the date range or time window.", "warn");
      return;
    }

    const picks = chooseSpreadOptions(candidates, settings.maxOptions, start, end);
    const output = buildEmailOutput(picks, settings);
    el.resultText.value = output.text;
    renderListPreview(output.lines);
    el.copyBtn.disabled = false;
    updateStatus(`Generated ${picks.length} options. Copy and paste into your email.`, "ok");
  } catch (error) {
    updateStatus(formatError(error), "warn");
  }
}

async function fetchIcalViaProxy(icalUrl) {
  const proxyUrl = CORS_PROXY + encodeURIComponent(icalUrl);
  const response = await fetch(proxyUrl);
  if (!response.ok) {
    throw new Error(`Could not fetch calendar (${response.status}). Check your iCal URL is correct and public.`);
  }
  const text = await response.text();
  if (!text.includes("BEGIN:VCALENDAR")) {
    throw new Error("The URL did not return a valid calendar. Make sure you copied the secret iCal address from Google Calendar.");
  }
  return text;
}

function readSettings() {
  return {
    durationMin: Number(el.durationMin.value),
    spanDays: Number(el.spanDays.value),
    maxOptions: Number(el.maxOptions.value),
    dayStart: el.dayStart.value,
    dayEnd: el.dayEnd.value,
    slotStep: Number(el.slotStep.value),
    leadHours: Number(el.leadHours.value),
    weekdaysOnly: el.weekdaysOnly.checked,
  };
}

function validateSettings(settings) {
  if (!Number.isFinite(settings.durationMin) || settings.durationMin < 5) {
    throw new Error("Meeting length must be at least 5 minutes.");
  }
  if (!Number.isFinite(settings.spanDays) || settings.spanDays < 1) {
    throw new Error("Look ahead must be at least 1 day.");
  }
  if (!Number.isFinite(settings.maxOptions) || settings.maxOptions < 1) {
    throw new Error("Number of options must be at least 1.");
  }
  if (!Number.isFinite(settings.slotStep) || settings.slotStep < 5) {
    throw new Error("Slot interval must be at least 5 minutes.");
  }
  const startMin = timeToMinutes(settings.dayStart);
  const endMin = timeToMinutes(settings.dayEnd);
  if (endMin <= startMin) throw new Error("Day end must be later than day start.");
  if (settings.durationMin > endMin - startMin) {
    throw new Error("Meeting length cannot exceed your daily time window.");
  }
}

function buildRange(settings) {
  const start = new Date();
  const end = new Date(start);
  end.setDate(end.getDate() + settings.spanDays);
  return { start, end };
}

// ---------- iCal parser ----------

function parseIcsBusyBlocks(icsText, rangeStart, rangeEnd) {
  const unfolded = icsText.replace(/\r?\n[ \t]/g, "");
  const lines = unfolded.split(/\r?\n/);
  const blocks = [];

  let inEvent = false;
  let event = {};

  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (!line) continue;

    if (line === "BEGIN:VEVENT") { inEvent = true; event = {}; continue; }

    if (line === "END:VEVENT") {
      if (inEvent) {
        const block = eventToBusyBlock(event);
        if (block && block.end > rangeStart && block.start < rangeEnd) {
          blocks.push(block);
        }
      }
      inEvent = false;
      event = {};
      continue;
    }

    if (!inEvent) continue;

    const sep = line.indexOf(":");
    if (sep === -1) continue;

    const keyPart = line.slice(0, sep);
    const value = line.slice(sep + 1);
    const [nameRaw, ...paramParts] = keyPart.split(";");
    const name = nameRaw.toUpperCase();
    const params = {};
    for (const part of paramParts) {
      const [k, v] = part.split("=");
      if (k && v) params[k.toUpperCase()] = v;
    }

    if (name === "DTSTART") event.dtStart = { value, params };
    else if (name === "DTEND") event.dtEnd = { value, params };
    else if (name === "TRANSP") event.transparency = value.toUpperCase();
    else if (name === "STATUS") event.status = value.toUpperCase();
  }

  blocks.sort((a, b) => a.start - b.start);
  return mergeOverlaps(blocks);
}

function eventToBusyBlock(event) {
  if (!event.dtStart) return null;
  if (event.status === "CANCELLED") return null;
  if (event.transparency === "TRANSPARENT") return null;

  const start = parseIcsDate(event.dtStart.value, event.dtStart.params);
  let end = event.dtEnd ? parseIcsDate(event.dtEnd.value, event.dtEnd.params) : null;

  if (!start || Number.isNaN(start.getTime())) return null;
  if (!end || Number.isNaN(end.getTime())) end = new Date(start.getTime() + 30 * 60 * 1000);
  if (end <= start) return null;

  return { start, end };
}

function parseIcsDate(value, params = {}) {
  const s = String(value || "").trim();
  if (params.VALUE === "DATE" || /^\d{8}$/.test(s)) {
    return new Date(Number(s.slice(0,4)), Number(s.slice(4,6))-1, Number(s.slice(6,8)));
  }
  const utc = s.match(/^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$/);
  if (utc) {
    const [,y,mo,d,h,mi,sec] = utc;
    return new Date(Date.UTC(+y,+mo-1,+d,+h,+mi,+sec));
  }
  const local = s.match(/^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})$/);
  if (local) {
    const [,y,mo,d,h,mi,sec] = local;
    return new Date(+y,+mo-1,+d,+h,+mi,+sec);
  }
  return new Date(s);
}

// ---------- slot building ----------

function mergeOverlaps(items) {
  if (items.length < 2) return items;
  const merged = [items[0]];
  for (let i = 1; i < items.length; i++) {
    const prev = merged[merged.length - 1];
    const cur = items[i];
    if (cur.start <= prev.end) { if (cur.end > prev.end) prev.end = cur.end; }
    else merged.push(cur);
  }
  return merged;
}

function buildCandidateSlots(rangeStart, rangeEnd, busyBlocks, settings) {
  const candidates = [];
  const dayStartMin = timeToMinutes(settings.dayStart);
  const dayEndMin = timeToMinutes(settings.dayEnd);
  const durationMs = settings.durationMin * 60 * 1000;
  const stepMs = settings.slotStep * 60 * 1000;
  const earliest = new Date(Date.now() + settings.leadHours * 60 * 60 * 1000);

  let cursor = new Date(rangeStart);
  cursor.setHours(0, 0, 0, 0);

  while (cursor < rangeEnd) {
    const day = cursor.getDay();
    if (!settings.weekdaysOnly || (day >= 1 && day <= 5)) {
      const windowStart = new Date(cursor);
      windowStart.setMinutes(dayStartMin, 0, 0);
      const windowEnd = new Date(cursor);
      windowEnd.setMinutes(dayEndMin, 0, 0);

      let slot = ceilToStep(new Date(Math.max(windowStart.getTime(), earliest.getTime())), stepMs);
      while (slot < windowEnd) {
        const slotEnd = new Date(slot.getTime() + durationMs);
        if (slotEnd > windowEnd || slotEnd > rangeEnd) break;
        if (!hasOverlap(slot, slotEnd, busyBlocks)) candidates.push(new Date(slot));
        slot = new Date(slot.getTime() + stepMs);
      }
    }
    cursor.setDate(cursor.getDate() + 1);
  }
  return candidates;
}

function ceilToStep(date, stepMs) {
  return new Date(Math.ceil(date.getTime() / stepMs) * stepMs);
}

function hasOverlap(slotStart, slotEnd, busyBlocks) {
  for (const busy of busyBlocks) {
    if (busy.end <= slotStart) continue;
    if (busy.start >= slotEnd) break;
    return true;
  }
  return false;
}

function chooseSpreadOptions(candidates, desiredCount, rangeStart, rangeEnd) {
  if (candidates.length <= desiredCount) return [...candidates];

  const selected = [];
  const seenDay = new Set();
  const seenBucket = new Set();
  const spanMs = Math.max(rangeEnd.getTime() - rangeStart.getTime(), 1);

  while (selected.length < desiredCount) {
    let bestCandidate = null;
    let bestScore = -Infinity;

    for (const slot of candidates) {
      if (selected.some((p) => p.getTime() === slot.getTime())) continue;
      const soonness = 1 - (slot.getTime() - rangeStart.getTime()) / spanMs;
      let nearestMs = Infinity;
      for (const p of selected) {
        const d = Math.abs(slot.getTime() - p.getTime());
        if (d < nearestMs) nearestMs = d;
      }
      const distScore = selected.length === 0 ? 0.7 : Math.min(1, nearestMs / spanMs);
      const dayBonus   = seenDay.has(toDayKey(slot)) ? 0 : 0.24;
      const buckBonus  = seenBucket.has(toTimeBucket(slot)) ? 0 : 0.18;
      const penalty    = nearestMs < 2 * 60 * 60 * 1000 ? 0.24 : 0;
      const score = 0.35 * soonness + 0.45 * distScore + dayBonus + buckBonus - penalty;
      if (score > bestScore) { bestScore = score; bestCandidate = slot; }
    }
    if (!bestCandidate) break;
    selected.push(bestCandidate);
    seenDay.add(toDayKey(bestCandidate));
    seenBucket.add(toTimeBucket(bestCandidate));
  }
  return selected.sort((a, b) => a - b);
}

function toDayKey(date) {
  return `${date.getFullYear()}-${date.getMonth()}-${date.getDate()}`;
}

function toTimeBucket(date) {
  const h = date.getHours();
  if (h < 11) return "morning";
  if (h < 14) return "midday";
  if (h < 17) return "afternoon";
  return "evening";
}

function buildEmailOutput(slots, settings) {
  const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
  const durationMs = settings.durationMin * 60 * 1000;
  const dayFmt  = new Intl.DateTimeFormat(undefined, { weekday: "short", month: "short", day: "numeric" });
  const timeFmt = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" });

  const lines = slots.map((slot, i) => {
    const end = new Date(slot.getTime() + durationMs);
    return `${i + 1}) ${dayFmt.format(slot)}: ${timeFmt.format(slot)} - ${timeFmt.format(end)}`;
  });

  const intro = `Here are ${slots.length} options for a ${settings.durationMin}-minute meeting in the next ${settings.spanDays} day(s) (${timeZone}):`;
  return { lines, text: `${intro}\n\n${lines.join("\n")}` };
}

function renderListPreview(lines) {
  el.resultList.innerHTML = "";
  for (const line of lines) {
    const li = document.createElement("li");
    li.textContent = line;
    el.resultList.appendChild(li);
  }
}

async function onCopy() {
  if (!el.resultText.value.trim()) return;
  try {
    await navigator.clipboard.writeText(el.resultText.value);
    updateStatus("Copied to clipboard.", "ok");
  } catch {
    updateStatus("Copy failed. Select the text and copy manually.", "warn");
  }
}

function timeToMinutes(hhmm) {
  const [h, m] = hhmm.split(":").map(Number);
  return h * 60 + m;
}

function formatError(error) {
  if (!error) return "Something went wrong.";
  if (typeof error === "string") return error;
  return error.message || "Something went wrong.";
}
