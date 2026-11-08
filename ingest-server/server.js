import http from "node:http";
import { randomBytes } from "node:crypto";

const PORT = Number(process.env.PORT || 8080);
const STALE_MS = 90_000;
const DISCONNECTED_MS = 180_000;
const INGEST_TOKEN = process.env.INGEST_TOKEN || randomBytes(24).toString("hex");

let current = null;

function readingFromStored(body) {
  const now = Date.now();
  const updatedAt = body?.updatedAt || body?.receivedAt;
  const updatedMs = updatedAt ? Date.parse(updatedAt) : NaN;
  const ageMs = Number.isFinite(updatedMs) ? now - updatedMs : Number.POSITIVE_INFINITY;
  const connection = body?.connection || "unknown";
  const hasTemp = typeof body?.temperatureF === "number" && body.temperatureF >= 0;

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
    unit: body?.unit || "F",
    raw: body?.raw ?? null,
    updatedAt: updatedAt || null,
    receivedAt: body?.receivedAt || null,
    connection,
    deviceName: body?.deviceName ?? null,
    deviceUUID: body?.deviceUUID ?? null,
    status,
    ageSeconds: Number.isFinite(ageMs) ? Math.round(ageMs / 1000) : null,
  };
}

const HTML = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>BlueDOT Live</title>
  <style>
    :root { color-scheme: light dark; font-family: ui-sans-serif, system-ui, sans-serif; }
    body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: #0f1419; color: #e7ecf3; }
    main { text-align: center; padding: 2rem; max-width: 28rem; }
    h1 { font-size: 1rem; font-weight: 600; letter-spacing: 0.08em; text-transform: uppercase; color: #8b9cb3; margin: 0 0 1rem; }
    .temp { font-size: 4.5rem; font-weight: 300; line-height: 1; margin: 0.25rem 0; }
    .unit { font-size: 2rem; opacity: 0.65; vertical-align: super; }
    .meta { margin-top: 1.5rem; font-size: 0.95rem; color: #9fb0c7; line-height: 1.6; }
    .badge { display: inline-block; margin-top: 1rem; padding: 0.35rem 0.75rem; border-radius: 999px; font-size: 0.8rem; font-weight: 600; text-transform: uppercase; letter-spacing: 0.06em; }
    .live { background: #163a28; color: #6ee7a8; }
    .stale { background: #3d3218; color: #f5c842; }
    .disconnected { background: #3a1c1c; color: #f87171; }
    .unknown { background: #2a2f3a; color: #a8b3c7; }
  </style>
</head>
<body>
  <main>
    <h1>ThermoWorks BlueDOT</h1>
    <p class="temp" id="temp">—<span class="unit">°F</span></p>
    <p class="meta" id="meta">Loading…</p>
    <span class="badge unknown" id="badge">connecting</span>
  </main>
  <script>
    const tempEl = document.getElementById('temp');
    const metaEl = document.getElementById('meta');
    const badgeEl = document.getElementById('badge');
    function fmtTime(iso) {
      if (!iso) return 'never';
      try { return new Date(iso).toLocaleString(); } catch { return iso; }
    }
    async function refresh() {
      try {
        const res = await fetch('/api/reading', { cache: 'no-store' });
        const data = await res.json();
        if (data.temperatureF != null) {
          tempEl.innerHTML = data.temperatureF.toFixed(1) + '<span class="unit">°F</span>';
        } else {
          tempEl.innerHTML = '—<span class="unit">°F</span>';
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

function sendJson(res, status, data) {
  const body = JSON.stringify(data, null, 2);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
  });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url || "/", `http://${req.headers.host}`);

  if (url.pathname === "/api/reading") {
  return sendJson(res, 200, current ? readingFromStored(current) : {
      temperatureF: null,
      unit: "F",
      status: "disconnected",
      updatedAt: null,
      ageSeconds: null,
    });
  }

  if (url.pathname === "/api/ingest" && req.method === "POST") {
    const auth = req.headers.authorization || "";
    if (auth !== `Bearer ${INGEST_TOKEN}`) {
      return sendJson(res, 401, { error: "unauthorized" });
    }
    let body;
    try {
      body = JSON.parse(await readBody(req));
    } catch {
      return sendJson(res, 400, { error: "invalid json" });
    }
    current = {
      ...body,
      receivedAt: new Date().toISOString(),
    };
    if (typeof current.temperatureF === "number" && current.temperatureF < 0) {
      delete current.temperatureF;
    }
    return sendJson(res, 200, { ok: true, reading: readingFromStored(current) });
  }

  if (url.pathname === "/" || url.pathname === "/index.html") {
    res.writeHead(200, {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
    });
    return res.end(HTML);
  }

  res.writeHead(404, { "content-type": "text/plain" });
  res.end("Not found");
});

server.listen(PORT, () => {
  if (!process.env.INGEST_TOKEN) {
    process.stderr.write(`INGEST_TOKEN=${INGEST_TOKEN}\n`);
  }
  process.stdout.write(`listening on ${PORT}\n`);
});
