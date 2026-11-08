import {
  readingFromStored,
  appendHistoryPoint,
  LIVE_PAGE_HTML,
} from "../../ingest-server/live-dashboard.js";

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

async function appendHistory(env, body) {
  let history = (await env.READINGS.get("history", "json")) || [];
  history = appendHistoryPoint(history, body);
  await env.READINGS.put("history", JSON.stringify(history));
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/api/reading") {
      const raw = await env.READINGS.get("current", "json");
      if (!raw) {
        return json({
          temperatureF: null,
          displayTemp: null,
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
      return new Response(LIVE_PAGE_HTML, {
        headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" },
      });
    }

    return new Response("Not found", { status: 404 });
  },
};