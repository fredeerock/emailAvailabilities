const STORAGE_KEY = "availability-composer-settings-v3";
const GOOGLE_SCOPE = "https://www.googleapis.com/auth/calendar.readonly";
const GOOGLE_EVENTS_URL = "https://www.googleapis.com/calendar/v3/calendars/primary/events";

const el = {
  googleClientId: document.getElementById("googleClientId"),
  googleSignInBtn: document.getElementById("googleSignInBtn"),
  googleSignOutBtn: document.getElementById("googleSignOutBtn"),
  authBadge: document.getElementById("authBadge"),
  redirectUriText: document.getElementById("redirectUriText"),
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

const pageUrl = new URL(window.location.href);
pageUrl.hash = "";
el.redirectUriText.textContent = pageUrl.origin;

let googleTokenClient = null;
let googleTokenClientId = "";
let googleAccessToken = "";

init();

function init() {
  applySavedSettings();
  el.googleClientId.addEventListener("change", () => {
    saveSettings();
    googleTokenClient = null;
    googleTokenClientId = "";
    googleAccessToken = "";
    updateAuthUi();
  });
  el.googleSignInBtn.addEventListener("click", onGoogleSignIn);
  el.googleSignOutBtn.addEventListener("click", onGoogleSignOut);
  el.generateBtn.addEventListener("click", onGenerate);
  el.copyBtn.addEventListener("click", onCopy);

  const settingInputs = [
    el.durationMin, el.spanDays, el.maxOptions,
    el.dayStart, el.dayEnd, el.slotStep, el.leadHours, el.weekdaysOnly,
  ];
  for (const input of settingInputs) {
    input.addEventListener("change", saveSettings);
  }

  updateAuthUi();
}

function applySavedSettings() {
  const defaults = {
    googleClientId: "",
    durationMin: "60",
    spanDays: "7",
    maxOptions: "5",
    dayStart: "09:00",
    dayEnd: "17:00",
    slotStep: "15",
    leadHours: "2",
    weekdaysOnly: true,
  };
  let saved = {};
  try {
    saved = JSON.parse(localStorage.getItem(STORAGE_KEY) || "{}");
  } catch {
    saved = {};
  }
  el.googleClientId.value = saved.googleClientId ?? defaults.googleClientId;
  el.durationMin.value = String(saved.durationMin ?? defaults.durationMin);
  el.spanDays.value = String(saved.spanDays ?? defaults.spanDays);
  el.maxOptions.value = String(saved.maxOptions ?? defaults.maxOptions);
  el.dayStart.value = saved.dayStart ?? defaults.dayStart;
  el.dayEnd.value = saved.dayEnd ?? defaults.dayEnd;
  el.slotStep.value = String(saved.slotStep ?? defaults.slotStep);
  el.leadHours.value = String(saved.leadHours ?? defaults.leadHours);
  el.weekdaysOnly.checked = saved.weekdaysOnly ?? defaults.weekdaysOnly;
}

function saveSettings() {
  localStorage.setItem(STORAGE_KEY, JSON.stringify({
    googleClientId: el.googleClientId.value.trim(),
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

function updateStatus(text, mode = "") {
  el.statusText.textContent = text;
  el.statusText.classList.remove("ok", "warn");
  if (mode) el.statusText.classList.add(mode);
}

function updateAuthUi() {
  const hasClientId = Boolean(el.googleClientId.value.trim());
  const signedIn = Boolean(googleAccessToken);

  el.googleSignInBtn.disabled = !hasClientId || signedIn;
  el.googleSignOutBtn.disabled = !signedIn;
  el.generateBtn.disabled = !signedIn;

  if (signedIn) {
    el.authBadge.textContent = "Google connected";
    el.authBadge.classList.add("ok");
    updateStatus("Ready. Click Find my times.", "ok");
  } else if (!hasClientId) {
    el.authBadge.textContent = "No client ID";
    el.authBadge.classList.remove("ok");
    updateStatus("Paste your Google OAuth Client ID, then sign in.", "warn");
  } else {
    el.authBadge.textContent = "Not signed in";
    el.authBadge.classList.remove("ok");
    updateStatus("Sign in with Google to connect your calendar.");
  }
}

async function onGoogleSignIn() {
  try {
    saveSettings();
    await requestGoogleAccessToken("consent");
    updateAuthUi();
  } catch (error) {
    updateStatus(formatError(error), "warn");
  }
}

function onGoogleSignOut() {
  if (googleAccessToken && window.google?.accounts?.oauth2?.revoke) {
    window.google.accounts.oauth2.revoke(googleAccessToken, () => {});
  }
  googleAccessToken = "";
  googleTokenClient = null;
  googleTokenClientId = "";
  updateAuthUi();
}

async function requestGoogleAccessToken(prompt = "") {
  const clientId = el.googleClientId.value.trim();
  if (!clientId) throw new Error("Missing Google OAuth client ID.");
  if (!window.google?.accounts?.oauth2) {
    throw new Error("Google Identity script did not load. Check your network or content blocker.");
  }

  if (!googleTokenClient || googleTokenClientId !== clientId) {
    googleTokenClient = window.google.accounts.oauth2.initTokenClient({
      client_id: clientId,
      scope: GOOGLE_SCOPE,
      callback: () => {},
      error_callback: () => {},
    });
    googleTokenClientId = clientId;
  }

  const tokenResponse = await new Promise((resolve, reject) => {
    googleTokenClient.callback = (resp) => {
      if (resp?.error) {
        reject(new Error(resp.error_description || resp.error));
        return;
      }
      resolve(resp);
    };
    googleTokenClient.error_callback = (resp) => {
      reject(new Error(resp?.message || "Google token request failed"));
    };
    googleTokenClient.requestAccessToken({ prompt });
  });

  if (!tokenResponse?.access_token) throw new Error("Google did not return an access token.");
  googleAccessToken = tokenResponse.access_token;
}

async function onGenerate() {
  el.copyBtn.disabled = true;
  el.resultList.innerHTML = "";
  el.resultText.value = "";

  try {
    const settings = readSettings();
    validateSettings(settings);
    saveSettings();

    updateStatus("Checking your calendar...");

    const { start, end } = buildRange(settings);

    let busyBlocks;
    try {
      busyBlocks = await fetchGoogleBusyBlocks(googleAccessToken, start, end);
    } catch (error) {
      if (String(error.message || "").includes("401")) {
        await requestGoogleAccessToken("");
        busyBlocks = await fetchGoogleBusyBlocks(googleAccessToken, start, end);
      } else {
        throw error;
      }
    }

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

async function fetchGoogleBusyBlocks(token, start, end) {
  let pageToken = "";
  const blocks = [];

  while (true) {
    const params = new URLSearchParams({
      timeMin: start.toISOString(),
      timeMax: end.toISOString(),
      singleEvents: "true",
      orderBy: "startTime",
      maxResults: "2500",
    });
    if (pageToken) params.set("pageToken", pageToken);

    const response = await fetch(`${GOOGLE_EVENTS_URL}?${params}`, {
      headers: { Authorization: `Bearer ${token}` },
    });

    if (!response.ok) {
      const bodyText = await response.text();
      throw new Error(`Google Calendar request failed (${response.status}): ${bodyText}`);
    }

    const payload = await response.json();

    for (const event of payload.items || []) {
      if (event.status === "cancelled" || event.transparency === "transparent") continue;
      const startDate = parseGoogleDate(event.start);
      const endDate = parseGoogleDate(event.end);
      if (!(startDate instanceof Date) || Number.isNaN(startDate.getTime())) continue;
      if (!(endDate instanceof Date) || Number.isNaN(endDate.getTime())) continue;
      if (endDate <= startDate) continue;
      blocks.push({ start: startDate, end: endDate });
    }

    pageToken = payload.nextPageToken || "";
    if (!pageToken) break;
  }

  blocks.sort((a, b) => a.start - b.start);
  return mergeOverlaps(blocks);
}

function parseGoogleDate(node) {
  if (!node) return null;
  if (node.dateTime) return new Date(node.dateTime);
  if (node.date) return new Date(`${node.date}T00:00:00`);
  return null;
}

function mergeOverlaps(items) {
  if (items.length < 2) return items;
  const merged = [items[0]];
  for (let i = 1; i < items.length; i++) {
    const prev = merged[merged.length - 1];
    const cur = items[i];
    if (cur.start <= prev.end) {
      if (cur.end > prev.end) prev.end = cur.end;
    } else {
      merged.push(cur);
    }
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
      for (const picked of selected) {
        const dist = Math.abs(slot.getTime() - picked.getTime());
        if (dist < nearestMs) nearestMs = dist;
      }
      const distanceScore = selected.length === 0 ? 0.7 : Math.min(1, nearestMs / spanMs);
      const dayBonus = seenDay.has(toDayKey(slot)) ? 0 : 0.24;
      const bucketBonus = seenBucket.has(toTimeBucket(slot)) ? 0 : 0.18;
      const closePenalty = nearestMs < 2 * 60 * 60 * 1000 ? 0.24 : 0;
      const score = 0.35 * soonness + 0.45 * distanceScore + dayBonus + bucketBonus - closePenalty;

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
  const dayFmt = new Intl.DateTimeFormat(undefined, { weekday: "short", month: "short", day: "numeric" });
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
  return error.errorMessage || error.message || "Something went wrong.";
}
