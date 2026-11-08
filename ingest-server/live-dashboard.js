/** Shared public dashboard HTML + reading helpers (Worker + home server). */

export const STALE_MS = 90_000;
export const DISCONNECTED_MS = 180_000;
export const HISTORY_MAX = 480;

export function readingFromStored(body) {
  const now = Date.now();
  const updatedAt = body?.updatedAt || body?.receivedAt;
  const updatedMs = updatedAt ? Date.parse(updatedAt) : NaN;
  const ageMs = Number.isFinite(updatedMs) ? now - updatedMs : Number.POSITIVE_INFINITY;
  const connection = body?.connection || "unknown";
  const hasTemp = typeof body?.temperatureF === "number" && body.temperatureF >= 0;
  const unit = body?.unit === "C" ? "C" : "F";

  let status = "live";
  if (connection === "disconnected" || connection === "bluetooth_off") {
    status = "disconnected";
  } else if (!hasTemp || ageMs > DISCONNECTED_MS) {
    status = "disconnected";
  } else if (ageMs > STALE_MS) {
    status = "stale";
  }

  let displayTemp = null;
  if (hasTemp) {
    displayTemp = unit === "C" ? (body.temperatureF - 32) * (5 / 9) : body.temperatureF;
  }

  return {
    temperatureF: hasTemp ? body.temperatureF : null,
    displayTemp,
    unit,
    raw: body?.raw ?? null,
    updatedAt: updatedAt || null,
    receivedAt: body?.receivedAt || null,
    connection,
    deviceName: body?.deviceName ?? null,
    deviceUUID: body?.deviceUUID ?? null,
    profileName: body?.profileName ?? null,
    cookTitle: body?.cookTitle ?? null,
    targetEnabled: Boolean(body?.targetEnabled),
    targetTempF: typeof body?.targetTempF === "number" ? body.targetTempF : null,
    targetEtaSeconds:
      typeof body?.targetEtaSeconds === "number" ? body.targetEtaSeconds : null,
    targetHeadline: body?.targetHeadline ?? null,
    sessionMinF: typeof body?.sessionMinF === "number" ? body.sessionMinF : null,
    sessionMaxF: typeof body?.sessionMaxF === "number" ? body.sessionMaxF : null,
    status,
    ageSeconds: Number.isFinite(ageMs) ? Math.round(ageMs / 1000) : null,
  };
}

export function appendHistoryPoint(history, body) {
  const temp = body?.temperatureF;
  if (typeof temp !== "number" || temp < 0) return history;
  const at = body.updatedAt || body.receivedAt || new Date().toISOString();
  const last = history[history.length - 1];
  if (last && last.t === temp && last.at === at) return history;
  const next = [...history, { t: temp, at }];
  if (next.length > HISTORY_MAX) return next.slice(-HISTORY_MAX);
  return next;
}

export const LIVE_PAGE_HTML = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <meta name="theme-color" content="#0a0e14" />
  <title>ProbeBeacon Live</title>
  <style>
    :root {
      color-scheme: dark;
      font-family: ui-sans-serif, system-ui, -apple-system, sans-serif;
      --ink: #0a0e14;
      --panel: rgba(255,255,255,0.06);
      --border: rgba(255,255,255,0.1);
      --muted: #8fa3be;
      --text: #e7ecf3;
      --accent: #4ade80;
      --warn: #f5c842;
      --bad: #f87171;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0; min-height: 100vh;
      background: radial-gradient(ellipse 120% 85% at 50% -10%, #1a2740 0%, var(--ink) 58%);
      color: var(--text);
    }
    .wrap { max-width: 36rem; margin: 0 auto; padding: 1.75rem 1.25rem 2.5rem; }
    .brand { display: flex; align-items: center; gap: 0.6rem; justify-content: center; margin-bottom: 0.35rem; }
    .brand svg { width: 1.25rem; height: 1.25rem; opacity: 0.85; }
    .brand span { font-size: 0.72rem; font-weight: 650; letter-spacing: 0.16em; text-transform: uppercase; color: var(--muted); }
    h1 { margin: 0; text-align: center; font-size: 1.35rem; font-weight: 600; letter-spacing: -0.02em; }
    .cook { text-align: center; margin: 0.35rem 0 0; font-size: 0.9rem; color: #b8c8dc; }
    .temp-row { text-align: center; margin: 1.1rem 0 0.25rem; }
    .temp { font-size: clamp(3.5rem, 14vw, 5.25rem); font-weight: 220; line-height: 1; font-variant-numeric: tabular-nums; margin: 0; }
    .unit { font-size: 0.42em; opacity: 0.55; vertical-align: super; margin-left: 0.08em; }
    .chips { display: flex; flex-wrap: wrap; gap: 0.45rem; justify-content: center; margin-top: 0.85rem; }
    .chip {
      font-size: 0.72rem; padding: 0.32rem 0.7rem; border-radius: 999px;
      background: var(--panel); border: 1px solid var(--border); color: #c5d4e8;
    }
    .chip strong { color: #eef3fb; font-weight: 600; }
    .badge { font-weight: 650; text-transform: uppercase; letter-spacing: 0.07em; }
    .live { border-color: rgba(110,231,168,0.35); color: #6ee7a8; }
    .stale { border-color: rgba(245,200,66,0.35); color: var(--warn); }
    .disconnected { border-color: rgba(248,113,113,0.35); color: var(--bad); }
    .unknown { color: #a8b3c7; }
    .target-card {
      margin-top: 1.25rem; padding: 1rem 1.1rem; border-radius: 14px;
      background: var(--panel); border: 1px solid var(--border);
    }
    .target-card[hidden] { display: none !important; }
    .target-top { display: flex; justify-content: space-between; align-items: baseline; gap: 0.75rem; font-size: 0.85rem; color: var(--muted); }
    .target-top strong { color: #dce6f4; font-size: 1rem; }
    .bar { margin-top: 0.65rem; height: 8px; border-radius: 999px; background: rgba(0,0,0,0.35); overflow: hidden; }
    .bar > i { display: block; height: 100%; width: 0%; background: linear-gradient(90deg, #22c55e, #4ade80); border-radius: 999px; transition: width 0.6s ease; }
    .eta { margin: 0.55rem 0 0; font-size: 0.88rem; color: #b5c6dc; line-height: 1.45; }
    .stats { display: grid; grid-template-columns: repeat(3, 1fr); gap: 0.55rem; margin-top: 1.1rem; }
    .stat { padding: 0.65rem 0.5rem; border-radius: 12px; background: var(--panel); border: 1px solid var(--border); text-align: center; }
    .stat label { display: block; font-size: 0.68rem; text-transform: uppercase; letter-spacing: 0.08em; color: var(--muted); }
    .stat b { display: block; margin-top: 0.25rem; font-size: 1.05rem; font-weight: 600; font-variant-numeric: tabular-nums; }
    canvas { display: block; width: 100%; height: 120px; margin-top: 1.15rem; border-radius: 12px; background: rgba(0,0,0,0.28); border: 1px solid var(--border); }
    .meta { margin-top: 1rem; text-align: center; font-size: 0.82rem; color: var(--muted); line-height: 1.55; }
    .footer { margin-top: 1.25rem; text-align: center; font-size: 0.72rem; color: #6d7d92; }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="brand">
      <svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M4.93 19.07l1.41-1.41M17.66 6.34l1.41-1.41" stroke="currentColor" stroke-width="1.5"/><circle cx="12" cy="12" r="4" stroke="#4ade80" stroke-width="1.5"/></svg>
      <span>ProbeBeacon</span>
    </div>
    <h1 id="title">Live BBQ</h1>
    <p class="cook" id="cook" hidden></p>
    <div class="temp-row">
      <p class="temp"><span id="temp-val">—</span><span class="unit" id="unit">°F</span></p>
    </div>
    <div class="chips" id="chips">
      <span class="chip badge unknown" id="badge">connecting</span>
    </div>
    <section class="target-card" id="target-card" hidden>
      <div class="target-top">
        <span>Target</span>
        <strong id="target-label">—</strong>
      </div>
      <div class="bar" aria-hidden="true"><i id="target-fill"></i></div>
      <p class="eta" id="eta">—</p>
    </section>
    <div class="stats" id="stats" hidden>
      <div class="stat"><label>Session min</label><b id="tmin">—</b></div>
      <div class="stat"><label>Session max</label><b id="tmax">—</b></div>
      <div class="stat"><label>Samples</label><b id="tpts">0</b></div>
    </div>
    <canvas id="chart" width="560" height="140"></canvas>
    <p class="meta" id="meta">Loading…</p>
    <p class="footer">Public read-only feed · no sign-in</p>
  </div>
  <script>
    const tempValEl = document.getElementById('temp-val');
    const unitEl = document.getElementById('unit');
    const metaEl = document.getElementById('meta');
    const badgeEl = document.getElementById('badge');
    const chipsEl = document.getElementById('chips');
    const chart = document.getElementById('chart');
    const ctx = chart.getContext('2d');
    const cookEl = document.getElementById('cook');
    const targetCard = document.getElementById('target-card');
    const targetFill = document.getElementById('target-fill');
    const targetLabel = document.getElementById('target-label');
    const etaEl = document.getElementById('eta');

    function fmtTime(iso) {
      if (!iso) return 'never';
      try { return new Date(iso).toLocaleString(); } catch { return iso; }
    }

    function toDisplay(tempF, unit) {
      if (tempF == null) return null;
      return unit === 'C' ? (tempF - 32) * (5 / 9) : tempF;
    }

    function fmtTemp(val, unit) {
      if (val == null) return '—';
      const n = unit === 'C' ? 1 : 1;
      return val.toFixed(n) + '°' + unit;
    }

    function setChips(data) {
      const chips = [];
      chips.push(badgeEl);
      badgeEl.textContent = data.status || 'unknown';
      badgeEl.className = 'chip badge ' + (data.status || 'unknown');
      if (data.profileName) {
        const el = document.createElement('span');
        el.className = 'chip';
        el.innerHTML = 'Driver <strong>' + data.profileName + '</strong>';
        chips.push(el);
      }
      if (data.deviceName) {
        const el = document.createElement('span');
        el.className = 'chip';
        el.innerHTML = 'Probe <strong>' + data.deviceName + '</strong>';
        chips.push(el);
      }
      chipsEl.replaceChildren(...chips);
    }

    function targetProgress(data) {
      if (!data.targetEnabled || data.targetTempF == null || data.temperatureF == null) return null;
      const cur = data.temperatureF;
      const tgt = data.targetTempF;
      if (Math.abs(tgt - cur) < 0.5) return 100;
      const start = data.sessionMinF != null ? data.sessionMinF : cur;
      const denom = tgt - start;
      if (Math.abs(denom) < 0.5) return 50;
      const p = ((cur - start) / denom) * 100;
      return Math.max(4, Math.min(100, p));
    }

    function drawChart(points, data) {
      const w = chart.width, h = chart.height;
      ctx.clearRect(0, 0, w, h);
      if (!points || points.length < 2) return;
      const temps = points.map(p => p.t);
      let min = Math.min(...temps), max = Math.max(...temps);
      if (data?.targetEnabled && typeof data.targetTempF === 'number') {
        min = Math.min(min, data.targetTempF);
        max = Math.max(max, data.targetTempF);
      }
      const pad = 10;
      const range = Math.max(max - min, 1);
      const yFor = (t) => h - pad - ((t - min) / range) * (h - pad * 2);
      ctx.strokeStyle = '#4ade80';
      ctx.lineWidth = 2;
      ctx.beginPath();
      points.forEach((p, i) => {
        const x = pad + (i / (points.length - 1)) * (w - pad * 2);
        const y = yFor(p.t);
        if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
      });
      ctx.stroke();
      ctx.fillStyle = 'rgba(74, 222, 128, 0.1)';
      ctx.lineTo(w - pad, h - pad);
      ctx.lineTo(pad, h - pad);
      ctx.closePath();
      ctx.fill();
      if (data?.targetEnabled && typeof data.targetTempF === 'number') {
        const y = yFor(data.targetTempF);
        ctx.strokeStyle = 'rgba(245, 200, 66, 0.9)';
        ctx.setLineDash([6, 6]);
        ctx.lineWidth = 1.5;
        ctx.beginPath();
        ctx.moveTo(pad, y);
        ctx.lineTo(w - pad, y);
        ctx.stroke();
        ctx.setLineDash([]);
      }
    }

    async function refresh() {
      try {
        const [readingRes, histRes] = await Promise.all([
          fetch('/api/reading', { cache: 'no-store' }),
          fetch('/api/history', { cache: 'no-store' }),
        ]);
        const data = await readingRes.json();
        const hist = await histRes.json();
        const points = hist.points || [];
        const unit = data.unit === 'C' ? 'C' : 'F';
        unitEl.textContent = '°' + unit;

        if (data.displayTemp != null) {
          tempValEl.textContent = data.displayTemp.toFixed(1);
        } else if (data.temperatureF != null) {
          const d = toDisplay(data.temperatureF, unit);
          tempValEl.textContent = d != null ? d.toFixed(1) : '—';
        } else {
          tempValEl.textContent = '—';
        }

        if (data.cookTitle) {
          cookEl.hidden = false;
          cookEl.textContent = data.cookTitle;
          document.getElementById('title').textContent = 'Cook in progress';
        } else {
          cookEl.hidden = true;
          document.getElementById('title').textContent = 'Live BBQ';
        }

        setChips(data);

        if (data.targetEnabled && data.targetTempF != null) {
          targetCard.hidden = false;
          targetLabel.textContent = fmtTemp(toDisplay(data.targetTempF, unit), unit);
          const pct = targetProgress(data);
          targetFill.style.width = (pct != null ? pct : 0) + '%';
          etaEl.textContent = data.targetHeadline || 'Heading to target…';
        } else {
          targetCard.hidden = true;
        }

        const minF = data.sessionMinF ?? (points.length ? Math.min(...points.map(p => p.t)) : null);
        const maxF = data.sessionMaxF ?? (points.length ? Math.max(...points.map(p => p.t)) : null);
        if (minF != null || maxF != null || points.length) {
          document.getElementById('stats').hidden = false;
          document.getElementById('tmin').textContent = minF != null ? fmtTemp(toDisplay(minF, unit), unit) : '—';
          document.getElementById('tmax').textContent = maxF != null ? fmtTemp(toDisplay(maxF, unit), unit) : '—';
          document.getElementById('tpts').textContent = String(points.length);
          drawChart(points.slice(-160), data);
        } else {
          document.getElementById('stats').hidden = true;
          ctx.clearRect(0, 0, chart.width, chart.height);
        }

        const lines = [
          'Updated ' + fmtTime(data.updatedAt),
          data.ageSeconds != null ? (data.ageSeconds + 's ago') : null,
          data.connection && data.connection !== 'unknown' ? ('Link: ' + data.connection) : null,
        ].filter(Boolean);
        metaEl.textContent = lines.join(' · ');
      } catch (e) {
        metaEl.textContent = 'Could not load reading.';
        badgeEl.textContent = 'error';
        badgeEl.className = 'chip badge disconnected';
      }
    }
    refresh();
    setInterval(refresh, 4000);
  </script>
</body>
</html>`;
