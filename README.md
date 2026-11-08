# ThermoWorks BlueDOT Manager

Open-source macOS app + live temperature dashboard for the [ThermoWorks BlueDOT](https://www.thermoworks.com/bluedot/) Bluetooth probe.

Stream BLE readings to a **public dashboard**, track **cooks**, **target ETA**, **alarms**, menu bar, and optional **iPhone push** (ntfy).

**BLE temperature:** characteristic `783F2991-23E0-4BDC-AC16-78601BD84B39` — bytes 1–4 are a **32-bit little-endian integer of whole °F** (not tenths). This repo implements discovery, decoding, and UI end-to-end; no external bridge app required.

## Quick start (download)

**No build tools required.**

1. Download the latest **BlueDOT-Manager-*.dmg** from [Releases](https://github.com/hudsonfoo/thermoworks-bluedot-manager/releases/latest).
2. Open the DMG and drag **BlueDOT Manager** into the **Applications** folder.
3. **First launch only** — macOS may say it can’t verify the app (open-source builds aren’t Apple-notarized). Use either method:
   - **Easiest:** In **Finder → Applications**, **right-click** (or Control-click) **BlueDOT Manager** → **Open** → click **Open** in the dialog. You only need to do this once; after that, double-click works.
   - **Or:** Open **Terminal** and run (adjust the path if needed):
     ```bash
     xattr -dr com.apple.quarantine "/Applications/BlueDOT Manager.app"
     ```
     Then open the app normally from Applications.
4. Allow **Bluetooth** and **Notifications** when prompted.
5. Turn on your BlueDOT — the app **finds it automatically** (no UUID hunting).
6. **Settings → Updates** or **File → Check for Updates…** — in-app upgrades from GitHub (optional auto-check on launch).

> **Why the security message?** Release builds are signed for local use but not notarized with Apple. The app is open source on GitHub; the right-click **Open** path is Apple’s standard way to approve a downloaded app you trust.

### Live dashboard (pick one)

**Option A — Cloudflare (HTTPS, works from anywhere)**  
See [Cloudflare setup](#cloudflare-https-recommended) below, then paste ingest URL + token in **Settings → Live dashboard**.

**Option B — Home network (your public IP)**  
In **Settings → Live dashboard**, choose **Home network**, tap **Detect IPs**, then **Start home server**. Forward the shown **TCP port** on your router to your Mac. Share `http://YOUR_PUBLIC_IP:PORT/` (HTTP). The app posts to a local server bundled inside the `.app` (requires [Node.js](https://nodejs.org/) installed).

## Build from source

```bash
git clone git@github.com:hudsonfoo/thermoworks-bluedot-manager.git
cd thermoworks-bluedot-manager
./build-manager.sh
open BlueDOTManager.app
```

DMG for maintainers: `./scripts/package-dmg.sh` → `build/BlueDOT-Manager-*.dmg`

## Cloudflare (HTTPS, recommended)

Credentials stay on the Worker (`INGEST_TOKEN`). Browsers only call `GET /api/reading`.

```bash
cd public-worker
npx wrangler login
npx wrangler kv namespace create READINGS
# Put namespace id in wrangler.toml
TOKEN=$(openssl rand -hex 32)
printf '%s' "$TOKEN" | npx wrangler secret put INGEST_TOKEN
npx wrangler deploy
```

In the Mac app **Settings → Live dashboard → Cloudflare**, set:

- **Ingest URL:** `https://bluedot-live.<you>.workers.dev/api/ingest`
- **Token:** same `TOKEN` as above → **Save settings**

Open the dashboard root URL in a browser (no token in the page).

## Home network (public IP)

Good if you prefer not to use Cloudflare and can forward a port on your router.

1. Install Node.js (`brew install node`) if needed.
2. **Settings → Live dashboard → Home network**
3. **Detect IPs** — shows LAN + public IPv4
4. **Start home server** — runs bundled `ingest-server` on the chosen port
5. On your router: **port forward** that TCP port to this Mac’s **LAN IP**
6. Remote viewers open `http://<public-ip>:<port>/`

The Mac app always ingests to `http://127.0.0.1:<port>/api/ingest` locally; visitors use the public IP URL. This is plain **HTTP** (no TLS) unless you add your own reverse proxy.

## Features

- Auto-discovery of **BlueDOT** by name (UUID saved after first connect); **multiple probes** (Settings → **Add BlueDOT…**)
- **Cooks** in `~/.config/bluedot-receiver/cooks.json` (24h gap → new cook, titles, manual **New cook**)
- Target **ETA**, **alarm** with dismiss/snooze, menu bar, ntfy iPhone push

## Config on disk (not in git)

| File | Purpose |
|------|---------|
| `~/.config/bluedot-receiver/config.json` | Ingest URL + token |
| `~/.config/bluedot-receiver/preferences.json` | App prefs |
| `~/.config/bluedot-receiver/cooks.json` | Cook history |

See `examples/`.

## Troubleshooting

| Issue | Fix |
|--------|-----|
| “Apple could not verify…” / app won’t open | First launch: **right-click → Open** in Applications (see [Quick start](#quick-start-download)), or clear quarantine with `xattr -dr com.apple.quarantine` on the `.app` |
| Bluetooth prompt every rebuild | Use the **release DMG** or `./build-manager.sh`; allow once in System Settings |
| Wrong temperature (÷10) | Fixed in 1.1+ — raw int is °F |
| Home server won’t start | Install Node; use release DMG (includes ingest-server in bundle) |
| Public page empty | Token must match server; keep app running + probe connected |

## License

MIT — [LICENSE](LICENSE)
