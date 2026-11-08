import http from "node:http";
import { randomBytes } from "node:crypto";
import {
  readingFromStored,
  appendHistoryPoint,
  LIVE_PAGE_HTML,
} from "./live-dashboard.js";

const PORT = Number(process.env.PORT || 8080);
const INGEST_TOKEN = process.env.INGEST_TOKEN || randomBytes(24).toString("hex");

let current = null;
let history = [];

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
    return sendJson(
      res,
      200,
      current
        ? readingFromStored(current)
        : {
            temperatureF: null,
            displayTemp: null,
            unit: "F",
            status: "disconnected",
            updatedAt: null,
            ageSeconds: null,
          }
    );
  }

  if (url.pathname === "/api/history") {
    return sendJson(res, 200, { points: history });
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
    history = appendHistoryPoint(history, current);
    return sendJson(res, 200, { ok: true, reading: readingFromStored(current) });
  }

  if (url.pathname === "/" || url.pathname === "/index.html") {
    res.writeHead(200, {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
    });
    return res.end(LIVE_PAGE_HTML);
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
