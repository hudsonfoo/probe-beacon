# ProbeBeacon

**ProbeBeacon** is a free, open-source **macOS Bluetooth meat thermometer app**: connect **MEATER**, **ThermoWorks BlueDOT**, **Thermapen Blue**, **Inkbird iBBQ**, and other BLE probes, stream live temps, track cooks, share a **public BBQ thermometer dashboard**, and get target alarms on your Mac or iPhone (ntfy).

> Formerly distributed as “BlueDOT Manager” — same project, now built for multiple brands.

## Supported Bluetooth thermometers

| Device | Driver in app | How it’s detected |
|--------|---------------|-------------------|
| [ThermoWorks BlueDOT](https://www.thermoworks.com/bluedot/) | ThermoWorks BlueDOT | BLE name `BlueDOT` |
| [MEATER](https://www.meater.com/) / MEATER+ / MEATER 2 | MEATER | Name `MEATER`, service `A75CC7FC-…` |
| [Thermapen Blue](https://www.thermoworks.com/thermapen-blue/) (ETI) | Thermapen Blue | Name `Thermapen`; press **Transfer** to send readings |
| [Inkbird iBBQ](https://inkbird.com/) / IBT-2x / 4x / 6x / 8x | Inkbird iBBQ | Names like `iBBQ`, `Inkbird`, `IBT-`; service `FFF0` |
| Other BLE cooking probes | **Auto-detect** | Thermometer-like name or GATT; infers payload shape (see [profiles/README.md](profiles/README.md)) |

**Auto-detect** tries standard BLE **Health Thermometer** (`0x1809`), common vendor characteristics, and ranked heuristics (scaled integers, floats, MEATER/Inkbird layouts) and locks onto a plausible food-temp stream.

PRs welcome for more profiles — see [Contributing](#contributing).

## Quick start (download)

**No build tools required.**

1. Download the latest **`ProbeBeacon-*.dmg`** from [Releases](https://github.com/hudsonfoo/thermoworks-bluedot-manager/releases/latest) (older assets may be named `BlueDOT-Manager-*.dmg`).
2. Open the DMG and drag **ProbeBeacon** into **Applications**.
3. **First launch** — macOS may say it can’t verify the app (not Apple-notarized). Either:
   - **Right-click** **ProbeBeacon** in Applications → **Open** → **Open** (once), or
   - `xattr -dr com.apple.quarantine "/Applications/ProbeBeacon.app"`
4. Allow **Bluetooth** and **Notifications**.
5. **Settings → Add thermometer…** — choose your brand (or Auto-detect), wake the probe nearby.
6. Optional: **File → Check for Updates…** for in-app upgrades.

### Live dashboard (pick one)

**Option A — Cloudflare (HTTPS)**  
Deploy the Worker in [Cloudflare setup](#cloudflare-https-recommended), then paste ingest URL + token under **Settings → Live dashboard**.

**Option B — Home network**  
**Settings → Home network** → **Detect IPs** → **Start home server** → port-forward on your router. Share `http://YOUR_PUBLIC_IP:PORT/` (HTTP). Requires [Node.js](https://nodejs.org/) on the Mac.

## Build from source

```bash
git clone git@github.com:hudsonfoo/thermoworks-bluedot-manager.git
cd thermoworks-bluedot-manager
./build-manager.sh
open ProbeBeacon.app
```

DMG: `./scripts/package-dmg.sh` → `build/ProbeBeacon-*.dmg`

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

In the Mac app **Settings → Live dashboard → Cloudflare**:

- **Ingest URL:** `https://your-worker.workers.dev/api/ingest`
- **Token:** same as `TOKEN` above → **Save settings**

## Home network (public IP)

1. Install Node.js if needed (`brew install node`).
2. **Settings → Live dashboard → Home network**
3. **Detect IPs** → **Start home server**
4. Forward the TCP port on your router to this Mac
5. Share `http://<public-ip>:<port>/`

## Features

- Multi-brand **Bluetooth thermometer** support (table above)
- **Multiple probes** at once; switch live view per probe
- **Cook history** with titles and charts
- Target **ETA**, **alarms**, menu bar, optional **ntfy** iPhone push
- In-app **GitHub updates**

## Config on disk (not in git)

Legacy folder name `bluedot-receiver` is unchanged for upgrades:

| File | Purpose |
|------|---------|
| `~/.config/bluedot-receiver/config.json` | Ingest URL + token |
| `~/.config/bluedot-receiver/preferences.json` | App prefs |
| `~/.config/bluedot-receiver/cooks.json` | Cook history |

See `examples/`.

## Troubleshooting

| Issue | Fix |
|--------|-----|
| “Apple could not verify…” | [Quick start](#quick-start-download) — right-click **Open** or `xattr` |
| Wrong or no temperature | **Settings → Probes → Driver** — pick the correct brand; Thermapen needs **Transfer** |
| MEATER not found | Wake probe; choose **MEATER** driver when pairing |
| Inkbird not streaming | Ensure probes are seated; use **Inkbird iBBQ** driver |
| Bluetooth prompt every rebuild | Use release DMG or `./build-manager.sh`; allow once in System Settings |
| Public page empty | Token must match server; app running + probe connected |

## Contributing

**Pull requests are welcome.** New thermometer profiles, docs, Worker/dashboard work, and UX polish all help. Open an issue before large changes.

## License

MIT — [LICENSE](LICENSE)
