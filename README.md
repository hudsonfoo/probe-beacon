# ThermoWorks BlueDOT Manager

Open-source macOS app + public live temperature page for the [ThermoWorks BlueDOT](https://www.thermoworks.com/bluedot/) Bluetooth probe.

Read temperature over BLE, stream to a **public HTTPS dashboard** (no secrets in the browser), track **cooks** with history, target **ETA**, **alarms**, and an optional **menu bar** widget. Optional **ntfy** push for iPhone alerts.

BLE protocol follows [artisan-websocket-bluedot](https://github.com/lamroger/artisan-websocket-bluedot): temperature is a **32-bit little-endian integer in °F** (whole degrees, not tenths).

## What you get

| Piece | Role |
|--------|------|
| **BlueDOT Manager** (`BlueDOTManager.swift`) | SwiftUI Mac app — BLE, cooks, targets, alarms, menu bar |
| **BlueDOT Receiver** (`BlueDOTReceiver.swift`) | Minimal legacy single-window receiver (optional) |
| **public-worker/** | Cloudflare Worker — ingest API + live chart page |
| **ingest-server/** | Optional Node server (local or Cloud Run) if you do not use Workers |

## Requirements

- **macOS** 14+ (SwiftUI Charts, modern notifications)
- **Xcode Command Line Tools** (`swiftc`, `codesign`)
- **ThermoWorks BlueDOT** paired / known to macOS Bluetooth
- **Cloudflare account** (free tier) *or* self-hosted `ingest-server`
- For iPhone push: [ntfy](https://ntfy.sh) app (optional)

## Quick start (Mac app)

```bash
git clone git@github.com:hudsonfoo/thermoworks-bluedot-manager.git
cd thermoworks-bluedot-manager
chmod +x build-manager.sh
./build-manager.sh
open BlueDOTManager.app
```

On first launch, allow **Bluetooth** and **Notifications** when prompted.

If macOS keeps re-prompting for Bluetooth after every rebuild, remove stale entries in **System Settings → Privacy & Security → Bluetooth**, then allow **BlueDOT Manager** once. Always use `./build-manager.sh` so the app is ad-hoc signed the same way.

### Find your BlueDOT device UUID

In **Bluetooth** settings, or from Terminal while scanning:

```bash
system_profiler SPBluetoothDataType 2>/dev/null | grep -i bluedot -A2
```

Set **Settings → Probe → Device UUID** in the app (default is an example UUID).

## Public live dashboard (Cloudflare Workers)

Credentials stay on the server (`INGEST_TOKEN`). The browser only calls `GET /api/reading`.

```bash
cd public-worker
npm init -y  # if you need a local package.json for wrangler; wrangler works with npx too
npx wrangler login
npx wrangler kv namespace create READINGS
# Put the returned id in wrangler.toml → [[kv_namespaces]] id = "..."
INGEST_TOKEN=$(openssl rand -hex 32)
printf '%s' "$INGEST_TOKEN" | npx wrangler secret put INGEST_TOKEN
npx wrangler deploy
```

Note your Worker URL, e.g. `https://bluedot-live.<account>.workers.dev`.

### Mac app ingest config

```bash
mkdir -p ~/.config/bluedot-receiver
TOKEN=$(openssl rand -hex 32)   # must match Worker secret if you rotate both together
cat > ~/.config/bluedot-receiver/config.json <<EOF
{
  "ingestURL": "https://bluedot-live.YOUR_SUBDOMAIN.workers.dev/api/ingest",
  "token": "$TOKEN"
}
EOF
```

See `examples/config.example.json`. Restart **BlueDOT Manager** (or save in **Settings → Cloud ingest**).

**Verify**

```bash
curl -sS "https://bluedot-live.YOUR_SUBDOMAIN.workers.dev/api/reading" | head
open "https://bluedot-live.YOUR_SUBDOMAIN.workers.dev/"
```

With the app running and connected to the probe, you should see a live temperature within a few seconds.

### Rotate token

```bash
printf '%s' "NEW_TOKEN" | npx wrangler secret put INGEST_TOKEN
# Update ~/.config/bluedot-receiver/config.json with the same token
```

## Optional: Node ingest server

For local-only or Google Cloud Run:

```bash
cd ingest-server
INGEST_TOKEN=$(openssl rand -hex 32) PORT=8787 node server.js
```

Point `config.json` `ingestURL` at `http://127.0.0.1:8787/api/ingest` (or your tunnel URL). Do not commit tokens.

## Features (Manager)

- **Live** — temperature, trend chart, session min/max
- **Target + ETA** — linear fit on recent readings; heating/cooling aware
- **Target alarm** — notification + repeating sound; overlay **Dismiss** / **Snooze**; ⌘D from menu bar
- **Cooks** — persisted under `~/.config/bluedot-receiver/cooks.json`; auto new cook after **24h** gap; manual **New cook**; optional titles
- **Public tab** — open/copy dashboard URL
- **iPhone (ntfy)** — Settings → enable topic; subscribe in ntfy app

## Data on disk

| Path | Contents |
|------|-----------|
| `~/.config/bluedot-receiver/config.json` | Ingest URL + token (secret) |
| `~/.config/bluedot-receiver/preferences.json` | App preferences |
| `~/.config/bluedot-receiver/cooks.json` | Cook sessions + readings |

These are **not** in the repo and must not be committed.

## Project layout

```
├── BlueDOTManager.swift      # Main app source
├── BlueDOTReceiver.swift     # Minimal receiver
├── build-manager.sh          # Compile + sign Manager
├── build-receiver.sh         # Compile + sign Receiver
├── BlueDOTManager.entitlements
├── BlueDOTManager.app/       # Bundle template (binary built locally)
├── public-worker/            # Cloudflare Worker
├── ingest-server/            # Optional Node backend
└── examples/                 # Sample config (no secrets)
```

## Troubleshooting

| Issue | Fix |
|--------|-----|
| App crashes on launch | Do not use `CBCentralManagerOptionRestoreIdentifierKey` on macOS; use current `main` branch + `./build-manager.sh` |
| Temp shown as 1/10 (e.g. 19.8 vs 198°F) | Fixed: raw integer is °F; see artisan repo |
| No notification sound | Enable sounds for BlueDOT Manager; use **Dismiss** on overlay; critical alerts need Apple entitlement (we use default + local beeps) |
| Public page empty | Check ingest token matches Worker secret; Mac app must be running and connected |
| Worker deploy KV error | Replace `REPLACE_WITH_YOUR_KV_NAMESPACE_ID` in `wrangler.toml` |

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgments

- Temperature BLE parsing: [lamroger/artisan-websocket-bluedot](https://github.com/lamroger/artisan-websocket-bluedot)
