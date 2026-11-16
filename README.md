# NetMon

A small native macOS menu bar app that monitors your internet connection.

- **Latency** to 1.1.1.1 and 8.8.8.8 (configurable), pinged once a second: last, avg, min, max, loss, jitter.
- **IPv6**: while your Mac has IPv6, every target gets an IPv6 twin on the same network, so IPv6-only problems show up.
- **mtr-style path analysis**: every hop is probed continuously and kept as a rolling window of 100 probes. The app then works out which hop is actually at fault (see below).
- **Throughput** via macOS's built-in `networkQuality`: download, upload, responsiveness (RPM) and idle RTT.
- **History & charts**: 15m / 1h from raw samples, 24h / 7d from per-minute rollups kept on disk.
- **Notifications** for connection down/restored, sustained loss, latency or jitter, bad hops, and slow downloads.

For how everything works in detail (measurement, diagnosis rules, alerts, data files, the API and the source layout), see **[docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md)**. The same guide is in the app under **Guide**.

No root, no dependencies. Probes use an unprivileged ICMP datagram socket, which macOS allows for normal users. It still receives the TTL-exceeded replies a hop trace needs.

## Install

Testing a build someone sent you? See [docs/TESTING.md](docs/TESTING.md). To make one: `scripts/package-test.sh` writes an app zip (with an installer) and a source zip to `dist/`.

Requires macOS 15+ and Xcode (or the Command Line Tools) with Swift 6.

```bash
./scripts/build-app.sh            # builds build/NetMon.app
./scripts/build-app.sh --install  # also copies to /Applications and launches it
```

It runs as a menu bar item showing a coloured dot (green/orange/red, blue during a speed test) and the current latency. Click it for a summary. **Open NetMon** opens the full window (Overview, Path, Throughput, Events, Settings, Guide). To start it automatically, turn on **Launch at login** in Settings.

The first notification will ask for permission. If you miss it, allow NetMon in System Settings › Notifications.

## How bad hops are identified

The rule mtr experts use: **a problem is only real if it carries forward to later hops.**

Routers rate-limit and deprioritise the ICMP replies they generate themselves. A hop can show 60% "loss" or 300 ms while the hops after it are clean. That is the router being too busy to answer you, not dropping or delaying your traffic. NetMon lists these under "Harmless anomalies".

What it flags:

| Finding | Rule |
|---|---|
| Packet loss starts at hop N | First hop from which every later hop, including the destination, shows ≥ half the destination's loss |
| Latency jumps at hop N | Largest step up (≥ 25 ms or +50%) that persists to the destination. Info only, unless destination latency is over your threshold |
| High jitter from hop N | Same carry-forward rule applied to jitter |
| Local network is slow | Hop 1 (your router) averages > 15 ms or spikes > 150 ms. Usually Wi-Fi or bufferbloat |
| Not answering | The destination stops replying. Reports the last hop that still answers |

Each finding says where the hop is: your router, a private/CGNAT address (your LAN or ISP access network), near you (ISP), or upstream.

**VPNs:** when traffic leaves through a tunnel interface (`utun*`, `ipsec*`, `wg*`…), only the hops inside the tunnel are visible. The first visible hop carries the whole tunnel's latency. NetMon detects this, says so, and doesn't blame your LAN.

## Speed tests

`networkQuality` saturates the link with parallel flows to Apple's CDN. A run takes 20–40 s and moves hundreds of MB or more. It therefore **never runs on a schedule**. It runs only:

- when you click **Speed test**, or
- automatically when another signal fires: a degraded-connection alert or a bad-hop finding. At most once per cooldown (default 60 min). Configurable, or turn it off.

While a test runs, and for a minute after, alerts and hop statistics pause, so the test's own load doesn't trigger false alarms.

## Using it from Claude (MCP + CLI)

The app serves its live data on a loopback-only HTTP API (`127.0.0.1`, random port). The same `NetMon` binary works as an **MCP server** and a **JSON CLI** that talk to that API. Both launch the app if it isn't running.

```bash
claude mcp add --scope user netmon -- /Applications/NetMon.app/Contents/MacOS/NetMon --mcp
```

| MCP tool | CLI | What it does |
|---|---|---|
| `netmon_status` | `netmon status` | Health, 60 s / 5 min latency, loss and jitter, key findings, last speed test, recent events |
| `netmon_path` | `netmon path [target]` | mtr-style hop table and diagnosis |
| `netmon_history` | `netmon history [target] [15m\|1h\|24h\|7d]` | Bucketed latency and loss over time |
| `netmon_events` | `netmon events [limit]` | Alerts, recoveries, speed tests |
| `netmon_throughput_history` | `netmon throughput [limit]` | Past speed tests |
| `netmon_run_speed_test` | `netmon speedtest [--no-wait]` | Runs networkQuality (heavy; see above) |
| `netmon_trace` | `netmon trace <host> [cycles]` | One-off trace and diagnosis to any host |
| `netmon_reset_path` | `netmon reset [target]` | Clears hop stats and rediscovers routes |
| `netmon_open_window` | `netmon open [section]` | Opens the window on a section (overview, path, throughput, events, settings, guide) |
| `netmon_get_settings` / `netmon_update_settings` | `netmon settings` / `netmon set k=v …` | Read or change settings (range-checked) |

`scripts/build-app.sh --install` symlinks the CLI to `~/.local/bin/netmon`. Tool definitions live in one place (`Sources/NetMon/API/Tools.swift`), so MCP and the CLI stay in sync. The MCP server also sends Claude instructions on how to read hop data (the carry-forward rule, VPN caveats, and when a speed test is worth its cost).

**Security:** the API binds to `127.0.0.1` only and requires a random bearer token. The token is regenerated at each launch and written to `~/Library/Application Support/NetMon/api.json` with mode `0600`, so other users and web pages can't reach it.

## Data

`~/Library/Application Support/NetMon/` holds JSON Lines files: `rollups.jsonl` (per-minute latency per target), `throughput.jsonl`, `events.jsonl`. They're pruned to the history window in Settings (default 7 days).

## Development

```bash
swift build && swift test
```

`swift run` works for quick iteration, but notifications only work from the bundled `.app`.
