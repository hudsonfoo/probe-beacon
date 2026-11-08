const STALE_MS = 90_000;
const DISCONNECTED_MS = 180_000;
const HISTORY_MAX = 480;

function json(data, status = 200, extra = {}) {
  return new Response(JSON.stringify(data, null, 2), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      ...extra,
    },
  });
}

function readingFromStored(body) {
  const now = Date.now();
  const updatedAt = body.updatedAt || body.receivedAt;
  const updatedMs = updatedAt ? Date.parse(updatedAt) : NaN;
  const ageMs = Number.isFinite(updatedMs) ? now - updatedMs : Number.POSITIVE_INFINITY;
  const connection = body.connection || "unknown";
  const hasTemp = typeof body.temperatureF === "number" && body.temperatureF >= 0;

  let status = "live";
  if (connection === "disconnected" || connection === "bluetooth_off") {
    status = "disconnected";
  } else if (!hasTemp || ageMs > DISCONNECTED_MS) {
    status = "disconnected";
  } else if (ageMs > STALE_MS) {
    status = "stale";
  }

  return {
    temperatureF: hasTemp ? body.temperatureF : null,
    unit: body.unit || "F",
    raw: body.raw ?? null,
    updatedAt: updatedAt || null,
    receivedAt: body.receivedAt || null,
    connection,
    deviceName: body.deviceName ?? null,
    deviceUUID: body.deviceUUID ?? null,
    status,
    ageSeconds: Number.isFinite(ageMs) ? Math.round(ageMs / 1000) : null,
  };
}

async function appendHistory(env, body) {
  const temp = body.temperatureF;
  if (typeof temp !== "number" || temp < 0) return;
  const at = body.updatedAt || body.receivedAt || new Date().toISOString();
  let history = (await env.READINGS.get("history", "json")) || [];
  const last = history[history.length - 1];
  if (last && last.t === temp && last.at === at) return;
  history.push({ t: temp, at });
  if (history.length > HISTORY_MAX) history = history.slice(-HISTORY_MAX);
  await env.READINGS.put("history", JSON.stringify(history));
}

const HTML = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>ProbeBeacon Live</title>
  <style>
    :root { color-scheme: dark; font-family: ui-sans-serif, system-ui, sans-serif; }
    * { box-sizing: border-box; }
    body { margin: 0; min-height: 100vh; background: radial-gradient(ellipse 120% 80% at 50% 0%, #1a2740 0%, #0a0e14 55%); color: #e7ecf3; }
    .wrap { max-width: 32rem; margin: 0 auto; padding: 2.5rem 1.5rem 3rem; text-align: center; }
    h1 { font-size: 0.75rem; font-weight: 600; letter-spacing: 0.14em; text-transform: uppercase; color: #7d8fa8; margin: 0 0 0.5rem; }
    .temp { font-size: 5rem; font-weight: 200; line-height: 1; margin: 0.5rem 0 0; font-variant-numeric: tabular-nums; }
    .unit { font-size: 2.25rem; opacity: 0.5; vertical-align: super; margin-left: 0.1rem; }
    .stats { display: flex; justify-content: center; gap: 1.25rem; margin-top: 1.25rem; font-size: 0.85rem; color: #8fa3be; }
    .stats strong { display: block; color: #c5d4e8; font-size: 1.05rem; font-weight: 500; }
    canvas { display: block; width: 100%; height: 100px; margin: 1.75rem 0 0; border-radius: 12px; background: rgba(0,0,0,0.25); }
    .meta { margin-top: 1.25rem; font-size: 0.9rem; color: #9fb0c7; line-height: 1.55; }
    .badge { display: inline-block; margin-top: 1rem; padding: 0.35rem 0.85rem; border-radius: 999px; font-size: 0.75rem; font-weight: 600; text-transform: uppercase; letter-spacing: 0.08em; }
    .live { background: #163a28; color: #6ee7a8; }
    .stale { background: #3d3218; color: #f5c842; }
    .disconnected { background: #3a1c1c; color: #f87171; }
    .unknown { background: #2a2f3a; color: #a8b3c7; }
  </style>
</head>
<body>
  <div class="wrap">
    <h1>Live BBQ temperature</h1>
    <p class="temp" id="temp">—<span class="unit">°F</span></p>
    <div class="stats" id="stats" hidden>
      <div>Session min<strong id="tmin">—</strong></div>
      <div>Session max<strong id="tmax">—</strong></div>
      <div>Points<strong id="tpts">0</strong></div>
    </div>
    <canvas id="chart" width="480" height="120"></canvas>
    <p class="meta" id="meta">Loading…</p>
    <span class="badge unknown" id="badge">connecting</span>
  </div>
  <script>
    const tempEl = document.getElementById('temp');
    const metaEl = document.getElementById('meta');
    const badgeEl = document.getElementById('badge');
    const chart = document.getElementById('chart');
    const ctx = chart.getContext('2d');

    function fmtTime(iso) {
      if (!iso) return 'never';
      try { return new Date(iso).toLocaleString(); } catch { return iso; }
    }

    function drawChart(points) {
      const w = chart.width, h = chart.height;
      ctx.clearRect(0, 0, w, h);
      if (!points || points.length < 2) return;
      const temps = points.map(p => p.t);
      const min = Math.min(...temps), max = Math.max(...temps);
      const pad = 8;
      const range = Math.max(max - min, 1);
      ctx.strokeStyle = '#4ade80';
      ctx.lineWidth = 2;
      ctx.beginPath();
      points.forEach((p, i) => {
        const x = pad + (i / (points.length - 1)) * (w - pad * 2);
        const y = h - pad - ((p.t - min) / range) * (h - pad * 2);
        if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
      });
      ctx.stroke();
      ctx.fillStyle = 'rgba(74, 222, 128, 0.12)';
      ctx.lineTo(w - pad, h - pad);
      ctx.lineTo(pad, h - pad);
      ctx.closePath();
      ctx.fill();
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
        if (data.temperatureF != null) {
          tempEl.innerHTML = data.temperatureF.toFixed(1) + '<span class="unit">°F</span>';
        } else {
          tempEl.innerHTML = '—<span class="unit">°F</span>';
        }
        if (points.length) {
          document.getElementById('stats').hidden = false;
          const temps = points.map(p => p.t);
          document.getElementById('tmin').textContent = Math.min(...temps).toFixed(1) + '°';
          document.getElementById('tmax').textContent = Math.max(...temps).toFixed(1) + '°';
          document.getElementById('tpts').textContent = String(points.length);
          drawChart(points.slice(-120));
        }
        const lines = [
          'Last update: ' + fmtTime(data.updatedAt),
          data.ageSeconds != null ? ('Age: ' + data.ageSeconds + 's') : null,
          data.deviceName ? ('Probe: ' + data.deviceName) : null,
        ].filter(Boolean);
        metaEl.textContent = lines.join(' · ');
        badgeEl.textContent = data.status;
        badgeEl.className = 'badge ' + (data.status || 'unknown');
      } catch (e) {
        metaEl.textContent = 'Could not load reading.';
        badgeEl.textContent = 'error';
        badgeEl.className = 'badge disconnected';
      }
    }
    refresh();
    setInterval(refresh, 5000);
  </script>
</body>
</html>`;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/api/reading") {
      const raw = await env.READINGS.get("current", "json");
      if (!raw) {
        return json({
          temperatureF: null,
          unit: "F",
          status: "disconnected",
          updatedAt: null,
          ageSeconds: null,
        });
      }
      return json(readingFromStored(raw));
    }

    if (url.pathname === "/api/history") {
      const points = (await env.READINGS.get("history", "json")) || [];
      return json({ points });
    }

    if (url.pathname === "/api/ingest" && request.method === "POST") {
      const auth = request.headers.get("Authorization") || "";
      const token = env.INGEST_TOKEN;
      if (!token || auth !== `Bearer ${token}`) {
        return json({ error: "unauthorized" }, 401);
      }
      let body;
      try {
        body = await request.json();
      } catch {
        return json({ error: "invalid json" }, 400);
      }
      const stored = {
        ...body,
        receivedAt: new Date().toISOString(),
      };
      if (typeof stored.temperatureF === "number" && stored.temperatureF < 0) {
        delete stored.temperatureF;
      }
      await env.READINGS.put("current", JSON.stringify(stored));
      await appendHistory(env, stored);
      return json({ ok: true, reading: readingFromStored(stored) });
    }

    if (url.pathname === "/" || url.pathname === "/index.html") {
      return new Response(HTML, {
        headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" },
      });
    }

    return new Response("Not found", { status: 404 });
  },
};
