# How NetMon works

NetMon watches your internet connection from the menu bar. It measures latency, packet loss and jitter to a few well-known hosts every second. It traces every router on the way, like mtr. It works out which hop, if any, is actually causing a problem. Claude can read all of it, and ask it to do things, through a local API.

This guide covers three things: what you see, how the measurements and diagnosis work, and how Claude and the CLI talk to the app. The same text is in the repo at `docs/HOW-IT-WORKS.md`.

## At a glance

| Part | What it does | How often |
|---|---|---|
| Latency ping | One ICMP echo to each target | Every 1 s (setting) |
| Hop trace | One probe per TTL, 1 to the destination + 2 | Every 2 s (setting) |
| Diagnosis | Re-reads the hop table and produces findings | After every trace |
| Alerts | Checks for sustained problems and notifies | Every 10 s |
| Minute rollups | Saves each minute's latency summary to disk | Every minute |
| Speed test | Runs macOS `networkQuality` | Only on demand or when an alert fires |
| IPv6 check | Adds or removes IPv6 twins of your targets | Every 30 s |
| Wi-Fi link | Signal, noise, link rate, channel, access point | Every 2 s |
| Wi-Fi scan | Finds nearby access points and scores channel crowding | Every 10 min (setting), or on demand |
| Local API | Serves live data to the CLI and Claude | Always on, loopback only |

The defaults watch **1.1.1.1** (Cloudflare) and **8.8.8.8** (Google). They are fast, anycast, and almost always up. When both go bad at once, the problem is very likely yours or your ISP's, not theirs. Adding a target on a third network, such as 9.9.9.9 (Quad9) or 208.67.222.222 (Cisco OpenDNS), makes that call clearer: if all three degrade together, it's your side. While your Mac has IPv6, each target also gets an IPv6 twin; see [IPv6](#ipv6).

## Using the app

### Menu bar

The menu bar item shows a coloured dot and the current latency, which is the lowest 10-second average across your targets.

| Dot | Meaning |
|---|---|
| Green | Healthy |
| Orange | Degraded: at least one target has loss or average latency over your threshold in the last 30 s, or is down |
| Red | Down: no replies from any target in the last 30 s |
| Gray | Starting up (fewer than 5 samples yet) |
| Blue | A speed test is running |

Click it for a summary. For each target it shows avg latency, loss, jitter, hop count and a sparkline of the last two minutes. On Wi-Fi it shows signal, channel, band, SNR and link rate, plus the worst Wi-Fi finding. It also shows the last speed test, a **Speed test** button, and **Open NetMon** (⌘O) for the full window.

### Overview

Latency over time for each target. Pick a range: **15m**, **1h**, **24h** or **7d**.

- **Stat cards:** avg, min, max, loss and jitter for each target over the range.
- **Round-trip time chart:** the average for each time bucket.
- **Packet loss chart:** the percentage lost in each bucket.
- **Recent events:** the latest alerts, recoveries and speed tests.

15m and 1h are drawn from the raw per-second samples held in memory, which keeps the last hour. 24h and 7d are drawn from the per-minute rollups saved on disk.

### Path

The mtr-style view. Pick a target at the top. **Reset** clears the hop statistics and rediscovers the route; use it after changing networks or connecting a VPN.

- **Findings** come first, most severe first. Each one names the hop where a problem starts and says roughly where that hop is: your router, your ISP, upstream, or inside a VPN tunnel. See [How bad hops are identified](#how-bad-hops-are-identified).
- **Hop table:** one row per TTL. A hop number in orange is part of a warning or critical finding.

| Column | Meaning |
|---|---|
| # | TTL: how many routers away |
| Host | Reverse DNS name and IP of the router that answered most often. "+N more (load-balanced)" means several routers share this hop (ECMP) |
| Loss | Share of the last 100 probes with no answer. Gray means the hop never answers, which is normal for routers that filter ICMP |
| Sent | Probes in the window (up to 100) |
| Last / Avg / Best / Worst | Round-trip times in ms over the window |
| StDev | Standard deviation of the round-trip times |
| Jitter | Mean difference between consecutive answers. High jitter hurts calls and games more than high latency does |

- **Latency profile by hop:** for each hop, a bar from best to worst and a dot at the average. A real latency problem shows as a step up that stays up for every later hop.

At the default 2 s trace interval, the 100-probe window covers about the last 3½ minutes.

### Wi-Fi

A Wi-Fi analyzer for the link this Mac is on and the networks around it. See [Wi-Fi analysis](#wi-fi-analysis) for how the numbers are worked out.

- **Cards:** signal (RSSI), signal-to-noise ratio with the noise floor, link rate, and channel with band, width and whether it is a DFS channel.
- **Details:** network name, Wi-Fi standard, security, access point address, the access point's own load report if it sends one, and whether internet traffic actually uses Wi-Fi.
- **Diagnosis:** Wi-Fi findings, most severe first.
- **Signal and noise chart:** shaded green (good), orange (weak) and red (very weak). Dashed purple lines mark roams and channel changes. Below it, link rate over time. Pick 15m, 1h, 24h or 7d.
- **Channel map:** every access point from the last scan, one band at a time. A block's width is its channel width and its height is its signal here; yours is highlighted. Overlapping blocks share airtime.
- **Channel load:** a score for each channel your router could use on this band and width, with a suggestion when one is clearly quieter.
- **Nearby access points:** the full scan, strongest first, with channel, signal, load (when broadcast), Wi-Fi standard and security.

**Scan now** runs a scan straight away. macOS shows network names, access point addresses and load reports only to apps with Location Services permission. Without it the screen says so and everything else still works.

| Signal (RSSI) | Meaning |
|---|---|
| −60 dBm or better | Excellent |
| −60 to −67 dBm | Good; fine for calls and video |
| −67 to −75 dBm | Weak; calls and games start to suffer |
| Below −75 dBm | Very weak; slow rates and packet loss |

### Throughput

Speed test history: download and upload in Mbps over time, and a table of every run.

- **Responsiveness (RPM):** round-trips per minute while the link is fully loaded. Below 300 is Low, 300–1000 Medium, above 1000 High. Low RPM with good Mbps means bufferbloat: big downloads make everything else laggy.
- **Base RTT:** latency while the link is idle.
- **MB used:** how much data the test moved.

See [Speed tests](#speed-tests) for when they run.

### Events

A persistent log, newest first: connection down/restored, degraded/recovered targets, path findings, speed tests and failures. The same events go to macOS notifications when those are on.

### Settings

| Setting | Default | Notes |
|---|---|---|
| Targets | 1.1.1.1, 8.8.8.8 | Hostnames, IPv4 or IPv6 addresses, comma-separated. Press Apply. IPv6 twins are added automatically and aren't listed here |
| Latency ping every | 1 s | 0.5–10 s |
| Hop trace every | 2 s | 1–30 s. One probe per hop per trace |
| Max hops | 30 | 5–64. Upper bound before the destination is found |
| Packet loss alert | 5 % | Sustained over 1 minute |
| Average latency alert | 150 ms | Sustained over 1 minute |
| Jitter alert | 40 ms | Sustained over 1 minute |
| Send macOS notifications | On | |
| Notify about bad hops | On | Path findings go to the Events log either way |
| Auto speed test when an alert fires | On | |
| At most once every | 60 min | 15–1440 min |
| Alert when download below | 0 (off) | Mbps |
| Launch at login | Off | |
| Keep history for | 7 days | 1–90 days |
| Wi-Fi neighbor scans every | 10 min | 0–240 min; 0 means only when you click Scan |

Settings take effect immediately; nothing needs a restart. **Show data folder in Finder** opens the folder described in [Data on disk](#data-on-disk).

### Guide

This page.

## How measurement works

### Probing without root

Normal ping and traceroute tools need raw sockets, and on macOS raw sockets need root. NetMon instead uses an unprivileged ICMP datagram socket, `socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)`, which macOS allows for any user. Crucially, the kernel also delivers the ICMP error messages a trace depends on: **Time Exceeded** (a router dropped the packet because its TTL ran out) and **Destination Unreachable**.

One socket per address family is shared by every probe in the app (IPv6 is described [below](#ipv6)):

1. Each probe gets a sequence number. The app's process id is the ICMP identifier.
2. The sender sets the socket's TTL and calls `sendto` under one lock, so concurrent probes with different TTLs can't pick up each other's TTL.
3. A dedicated receive thread reads every reply. macOS includes the IP header on these sockets, so the parser skips it (an IPv4 header starts with nibble 4, which no ICMP type does).
4. An **echo reply** carries our identifier and sequence directly. A **Time Exceeded** or **Unreachable** message quotes the start of our original packet, so the identifier and sequence are read from that quote. Replies that aren't ours are ignored.
5. A probe with no reply after 2 s counts as a timeout.

Round-trip time is measured with the monotonic clock from just before `sendto` to the moment the receive thread reads the reply.

### Latency ping

Each target gets one echo request (TTL 64) per ping interval. Probes are fire-and-forget: the next one goes out on schedule even if the previous one is still waiting, so one slow reply doesn't delay the sampling. Results are kept in send order for an hour.

The figures shown as "last 60 s" or "last 5 min" ignore the newest 2.5 s, because probes sent in that time may still be in flight and would otherwise look like loss.

### Statistics

| Figure | Definition |
|---|---|
| Loss | (sent − received) ÷ sent |
| Avg / Best / Worst | Mean, minimum and maximum of answered round-trip times |
| StDev | Population standard deviation of answered round-trip times |
| Jitter | Mean absolute difference between consecutive answered round-trip times (as in RFC 3550) |

### Hop tracing

Every trace interval, NetMon sends one probe per TTL from 1 up to a limit, all at once. A router that receives a packet whose TTL runs out answers with Time Exceeded; that reply reveals the router's address and the round-trip time to it. The destination answers the probe that reaches it with an echo reply.

Each hop keeps a rolling window of its last 100 results, plus a count of which addresses answered. Several addresses at one TTL mean load-balanced paths (ECMP). The table shows the most frequent one and lists the others when they account for at least 10% of answers.

**Finding the destination.** The destination TTL is the lowest TTL that got echo replies in at least 3 of its last 5 traces. A single echo reply is not enough. VPN clients and tunnels sometimes answer a low TTL with an echo reply, and believing it would collapse the path to one hop. Once the destination is known:

- Probing continues to 2 hops past it, so a route that gets longer is noticed.
- Hops beyond the destination are dropped.
- Echo replies already recorded at TTLs short of the destination are removed, since a real router there could not have produced one. VPN tunnels often answer every TTL with an echo reply on the very first burst; this is what cleans that up.

Reverse DNS names are looked up in the background and cached, so a slow DNS server never stalls the trace.

### IPv6

NetMon checks every 30 seconds whether the Mac has working IPv6. It asks the system for a route to an IPv6 internet address from an address that isn't link-local or unique-local; nothing is sent. While IPv6 works, every target gets an **IPv6 twin**, monitored exactly like the IPv4 target: ping, hop trace, diagnosis, alerts and history.

| Configured target | Its IPv6 twin |
|---|---|
| 1.1.1.1 / 1.0.0.1 (Cloudflare) | 2606:4700:4700::1111 / ::1001 |
| 8.8.8.8 / 8.8.4.4 (Google) | 2001:4860:4860::8888 / ::8844 |
| 9.9.9.9 / 149.112.112.112 (Quad9) | 2620:fe::fe / 2620:fe::9 |
| 208.67.222.222 / 208.67.220.220 (Cisco OpenDNS) | 2620:119:35::35 / 2620:119:53::53 |
| A hostname, e.g. example.com | "example.com (IPv6)": its IPv6 (AAAA) address |
| Any other IPv4 address | No twin |

Twins appear right after their IPv4 target, with an **IPv6** badge. When IPv6 appears or disappears, NetMon logs an event and sends a notification. The twins stop while IPv6 is gone, and they don't count as down. Their history is kept under the twin's name, so it reappears when IPv6 comes back.

Why monitor both: IPv4 and IPv6 often take different routes through your ISP, and one can be broken or slow while the other is fine. Browsers and most apps prefer IPv6 when it exists, so a bad IPv6 path feels like "the internet is slow" even when the IPv4 numbers are perfect. A problem on the twins only is an IPv6 problem; report it to your ISP as such.

Probing works the same way over an unprivileged ICMPv6 socket. The hop limit replaces the TTL. Replies are ICMPv6 echo replies (type 129), Time Exceeded (type 3) and Destination Unreachable (type 1), and errors quote our original request after the 40-byte IPv6 header. Unlike IPv4, the kernel computes the checksum and delivers no IP header. Private IPv6 addresses (fc00::/7, fe80::/10) count as local in the diagnosis.

An IPv6 probe is sent only if the system has a route to its destination (checked at most every 5 s); otherwise it fails at once. Without that check, macOS answers sends to an unroutable IPv6 address with local Unreachable errors and, after a dozen or so, blocks `sendto` indefinitely. Sends for each family also run on their own serial queue, so a stuck send can't stall IPv4 or the rest of the app.

You can also type IPv6 addresses into Targets yourself; those are monitored whether or not the IPv6 check passes.

### VPN detection

Every 15 traces, NetMon checks which network interface carries traffic to each target. It connects a UDP socket toward the target (which sends nothing), reads the local address the system picked, and matches that address to an interface. Interfaces named `utun*`, `ipsec*`, `ppp*`, `tun*` or `wg*` mean a VPN tunnel.

Through a tunnel, the hops between you and the VPN server are invisible; they are inside the encrypted tunnel. The first visible hop is usually the VPN server's side, and its latency includes your Wi-Fi, your ISP and the tunnel. NetMon adjusts its diagnosis for this; see below.

### Wi-Fi analysis

NetMon reads Wi-Fi through Apple's CoreWLAN framework. It needs no admin rights.

**The link, every 2 s.** Signal (RSSI), noise floor, link rate, channel, band, width, Wi-Fi standard, security and transmit power. Reading these doesn't disturb the connection. NetMon keeps an hour of samples in memory and saves a per-minute summary to `wifi.jsonl`. A change of access point or channel is logged as a roam. NetMon also checks which interface carries internet traffic: when Ethernet does, Wi-Fi findings say so and are never blamed for latency.

**Scans, every 10 minutes.** A scan lists every access point in range with its channel, width and signal. Scans are costly: the radio leaves your channel to listen on every other one, which takes 5–30 s (6 GHz and DFS channels are scanned passively) and causes latency spikes meanwhile. So scans are infrequent, skipped during speed tests, and followed by the same pause as a speed test: **no alerts and no hop statistics during a scan and for 60 s after.**

**Channel load.** For each channel, NetMon adds up the other access points whose frequency range overlaps it. Each one counts from 0 (at −90 dBm, barely audible) to 1 (at −50 dBm or stronger). One whose primary channel differs but overlaps counts 1.3×, because radios that can't decode each other's frames collide instead of taking turns. An access point that reports its own utilization counts more when busy. Your own network is left out: your access point, other access points with the same network name (mesh nodes and other bands, which move channel with your router), and extra networks on the same radio, such as a guest network. Those share a radio and differ only in the access point address's locally-administered bit or last byte. A neighbor's radio that broadcasts several networks counts once. The score is roughly "how many strong networks you share airtime with". 3 or more is crowded; 5 or more is a warning.

**Recommendation.** NetMon suggests another channel on the same band and width only when yours scores at least 1 and the other scores at least 1 lower. Non-DFS channels are preferred when they're nearly as quiet, because DFS channels must go quiet for a while if the router detects radar. Only the router can change its channel.

**Access point load (BSS Load).** Many business-grade and some home access points broadcast how many devices are connected and what share of time the channel is busy. NetMon reads it from the beacon data when it's there. macOS hides beacon data without Location permission.

**Location permission.** Since macOS 14.4, an app sees network names, access point addresses and beacon data only with Location Services permission. NetMon asks once. It never reads or stores your location. Signal, noise, channel, scanning and congestion work without permission. Because the app is ad-hoc signed, macOS may ask again after a rebuild.

**What macOS doesn't expose:** true airtime use and retry counts (those need monitor mode or the router's own tools), MCS index, and interference from things that aren't Wi-Fi. That last one shows up only indirectly, as a higher noise floor.

| Wi-Fi finding | Severity | Rule |
|---|---|---|
| Weak / very weak signal | Warning / critical | RSSI below −67 / −75 dBm |
| Low / very low signal-to-noise | Warning / critical | SNR below 25 / 15 dB |
| High noise floor | Warning | Noise above −75 dBm: likely non-Wi-Fi interference |
| Low link rate | Warning | Under 30 Mbps |
| On 2.4 GHz | Info, or warning if the same network name is seen on 5/6 GHz | |
| 2.4 GHz channel overlaps its neighbors | Info | Not channel 1, 6 or 11 |
| Frequent roaming | Warning | 4 or more access point or channel changes in 10 minutes |
| Access point channel busy | Warning | Your access point reports 70% or more utilization |
| Crowded channel | Info at score 3, warning at 5 | See channel load above |
| Wi-Fi is the likely cause of first-hop delay | Critical | Hop 1 averages 20 ms or more, jitter 15 ms or more, or loss 5% or more, **and** a Wi-Fi warning is active |
| Router slow to answer, but Wi-Fi looks fine | Warning | Hop 1 is slow as above with no Wi-Fi warning: points at the router or bufferbloat |
| Network names hidden | Info | No Location permission |
| Wi-Fi link looks good | OK | No warning or critical finding |

The two first-hop findings tie Wi-Fi to the latency NetMon already measures. Hop 1 is your Wi-Fi link plus the router, so a slow hop 1 with a weak or crowded link points at Wi-Fi. A slow hop 1 with a clean link points at the router. Targets reached through a VPN are skipped, since their first hop is inside the tunnel.

## How bad hops are identified

### The carry-forward rule

Routers forward traffic in hardware but answer probes in software, at low priority and rate-limited. So a router can show 60% "loss" or 300 ms while the hops after it are perfectly clean. That is the router being too busy to answer you, not dropping or delaying the traffic it forwards.

The rule experienced mtr users apply, and NetMon applies automatically: **a problem is only real if it carries forward to every later hop, including the destination.** Anything that doesn't carry forward is listed under "Harmless anomalies".

Diagnosis waits until each hop has at least 10 probes ("Collecting path data…").

### Findings

| Finding | Severity | Rule |
|---|---|---|
| *target* is not answering | Critical if the last answering hop is 1 or 2, else warning | No confirmed destination. Reports the last hop that still answers |
| Packet loss starts at hop N | Critical if destination loss ≥ your loss threshold, else warning | Destination loss ≥ 2%. Hop N is the first hop from which every later hop shows at least half the destination's loss |
| N% loss at the destination only | Warning or info | As above, but every earlier hop is clean: rate limiting at the destination, or loss on its last link |
| Latency jumps +X ms at hop N | Warning if destination avg ≥ your latency threshold, else info | The biggest step up of at least 25 ms and +50% that persists (the destination keeps at least 70% of the step). Hops with fewer than 5 answers are ignored |
| Local network is slow | Warning | Hop 1 averages over 15 ms or peaks over 150 ms. Usually Wi-Fi or bufferbloat. Skipped through a VPN |
| High jitter from hop N | Warning | Destination jitter ≥ your jitter threshold. Hop N is the first hop from which every later hop has at least 60% of it |
| Harmless anomalies | Info | Hops with ≥ 10% loss that a later hop doesn't share; hops more than 50 ms slower than the destination; hops that never answer |
| Measuring through a VPN | Info | Traffic leaves through a tunnel interface |
| Path looks healthy | OK | No warning or critical finding |

### Where is the hop?

Each finding says roughly where its hop is, to tell you who can fix it:

| Hop | Description |
|---|---|
| First visible hop through a VPN | Includes the whole tunnel. Compare with the VPN off |
| Hop 1 | Your own router or Wi-Fi |
| Private address (10/8, 172.16/12, 192.168/16, 100.64/10 CGNAT, 169.254/16, fc00::/7, fe80::/10) | Your LAN or your ISP's access network |
| Hop 2 or 3 | Most likely your ISP's access network |
| Further out | Upstream of your ISP. You can't fix it, but you can report it |

### Reading the Path screen yourself

1. Look at the **destination** row first. If its loss and latency are fine, the path is fine, whatever earlier hops show.
2. If the destination is bad, walk back up the table to the **first hop where the problem appears and stays**. That hop, or the link just before it, is the suspect.
3. A hop that is bad while later hops are good is rate limiting. Ignore it.
4. Silent hops (gray, 100% loss) are routers that don't answer probes. Ignore them.
5. Compare targets. A problem on all of them that starts at the same early hop is local or your ISP. A problem on only one target is on that provider's side. A problem on the IPv6 twins only is an IPv6 problem.

## Alerts and notifications

Every 10 seconds NetMon checks the following. Each alert is edge-triggered: it fires once when a state starts and once when it ends, not repeatedly.

- **Connection down:** every target has sent at least 5 probes in the last 20 s and none were answered. It recovers when any target answers again, and the recovery says how long it was down.
- **Degraded connection to a target:** over the last 60 s (at least 20 probes), loss, average latency or jitter is at or over its threshold. It includes the likely cause if a path finding is at warning or above. To avoid flapping, it recovers only once all three are comfortably below threshold: loss under half the threshold, latency and jitter under 80% of theirs.
- **Path findings:** a warning or critical finding that has persisted for 60 s. The same finding repeats at most every 30 minutes.
- **Wi-Fi findings:** the same rule as path findings, under the "Wi-Fi" name. Unlike path findings, they don't trigger a speed test. Wi-Fi disconnects, reconnects and roams are logged as events.
- **Slow download:** a speed test came in under your minimum download setting.

While the connection is down, degradation and path alerts are held back; one "down" alert says it all. Everything is written to the Events log. Notifications are sent only when they are switched on, and critical ones play a sound.

## Speed tests

A speed test runs macOS's built-in `networkQuality -c`. It opens many parallel HTTP/2 connections to Apple's CDN, saturates the link in both directions, and measures throughput and responsiveness under load. A run takes 20–40 s and can move hundreds of megabytes or more.

So it **never runs on a timer.** It runs only:

- when you click **Speed test** or **Run speed test**, or when Claude runs one, or
- automatically, when a degraded-connection alert or a path finding fires, at most once per cooldown (default 60 minutes), and only if auto speed tests are on.

A test saturates your own link, so anything measured while it runs is self-inflicted. During a test, and for 60 s after, **alerts are not evaluated and hop statistics are not updated.** Latency samples are still recorded, so the charts show what the test did to your latency.

## Data on disk

Everything lives in `~/Library/Application Support/NetMon/`:

| File | Contents |
|---|---|
| `rollups.jsonl` | One line per target per minute: sent, received, avg, min, max, jitter |
| `throughput.jsonl` | One line per speed test |
| `events.jsonl` | One line per event |
| `wifi.jsonl` | One line per minute on Wi-Fi: average and minimum signal, noise, average and minimum link rate, channel, access point |
| `api.json` | Port, token and process id of the running app's API (mode 0600) |

The `.jsonl` files are JSON Lines, with dates as Unix seconds. They are loaded at launch and trimmed to the history window. Speed tests are kept 23 days beyond the history window (30 days at the default), so the Throughput screen has more history. Raw per-second samples and hop windows are kept in memory only.

Settings are stored in macOS user defaults under the bundle id `com.babyscripts.netmon`. (Builds before the rename used `me.craig.netmon`; the first launch after it copies those settings over.)

## Claude, MCP and the CLI

### How the pieces connect

The app runs a small HTTP API on the loopback interface. The same `NetMon` executable has two other modes that are clients of that API:

| Invocation | Mode |
|---|---|
| `NetMon` (or opening NetMon.app) | The app |
| `NetMon --mcp` | MCP server for Claude, speaking JSON-RPC on stdin/stdout |
| `netmon <command>` (a symlink to the same binary) | CLI that prints JSON |

Both clients read `api.json` to find the app. If the app isn't running, or the process in `api.json` is gone, they launch it with `open` and wait up to 10 s for its API.

Register the MCP server with Claude Code once, for all projects:

```
claude mcp add --scope user netmon -- /Applications/NetMon.app/Contents/MacOS/NetMon --mcp
```

When Claude connects, the server sends it instructions on reading the data: the carry-forward rule, the VPN caveat, and that speed tests are expensive.

### Tools and commands

| MCP tool | CLI | Read-only | What it does |
|---|---|---|---|
| `netmon_status` | `netmon status` | Yes | Health, 60 s and 5 min stats, important findings, VPN, last speed test, recent events, thresholds, whether IPv6 is available. Each target says its `ipVersion`; twins say which target they mirror (`twinOf`). The starting point |
| `netmon_path` | `netmon path [target]` | Yes | The hop table and findings |
| `netmon_history` | `netmon history [target] [15m\|1h\|24h\|7d] [points]` | Yes | A summary for the range, the worst periods (3 worst buckets each by average latency, loss and spike, with times), and up to 60 trend buckets (`points` changes it) |
| `netmon_wifi` | `netmon wifi [--scan] [range] [points]` | Yes | Wi-Fi link, findings, neighbors, channel load scores, recommendation, roams and signal history. `scan` forces a fresh scan (5–30 s). `/status` also carries a short Wi-Fi summary |
| `netmon_events` | `netmon events [limit]` | Yes | Event log, newest first; MCP can also filter by minutes |
| `netmon_throughput_history` | `netmon throughput [limit]` | Yes | Past speed tests |
| `netmon_trace` | `netmon trace <host> [cycles]` | Yes | One-off trace and diagnosis to any host |
| `netmon_run_speed_test` | `netmon speedtest [--no-wait]` | No | Runs a speed test; waits for the result by default |
| `netmon_reset_path` | `netmon reset [target]` | No | Clears hop stats and rediscovers routes |
| `netmon_open_window` | `netmon open [section]` | No | Opens the window on overview, path, wi-fi, throughput, events, settings or guide |
| `netmon_get_settings` | `netmon settings` | Yes | All settings |
| `netmon_update_settings` | `netmon set key=value …` | No | Changes settings |

The tool definitions live in one place, `Sources/NetMon/API/Tools.swift`, which drives both the MCP tool list and the CLI, so the two can't drift apart.

**One-off traces** use the same tracer and diagnosis as the monitors, with a fresh hop table. They use IPv4 unless the host is an IPv6 address or has no IPv4 address. Each round is about 1 s, or about 2 s when some hops never answer (they wait out the timeout). The default 15 rounds takes 15–30 s; the maximum is 60.

**Settings** use these names over the API: `targets`, `ping_interval_seconds`, `trace_interval_seconds`, `max_hops`, `loss_alert_percent`, `latency_alert_ms`, `jitter_alert_ms`, `notifications_enabled`, `notify_path_findings`, `auto_speed_test`, `speed_test_cooldown_minutes`, `min_download_mbps`, `history_days`, `wifi_scan_interval_minutes`. Every value is range-checked before anything is written, so one bad value changes nothing. In the CLI, `targets=1.1.1.1,9.9.9.9` sets a list, and `true`, `false` and numbers are typed automatically.

### HTTP API

All requests need `Authorization: Bearer <token>`, using the token from `api.json`. Responses are JSON. Errors are `{"error": "…"}` with a 4xx or 5xx status.

| Method and path | Parameters |
|---|---|
| `GET /status` | |
| `GET /path` | `target` |
| `GET /history` | `target`, `range`, `points` |
| `GET /events` | `limit`, `since_minutes` |
| `GET /throughput` | `limit` |
| `GET /wifi` | `range`, `points` |
| `POST /wifi/scan` | `{"range": "1h", "points": 60}`; scans, then returns the same as `GET /wifi` |
| `GET /settings` | |
| `POST /speedtest` | `{"wait": true}` |
| `POST /trace` | `{"host": "…", "cycles": 15, "max_hops": 30}` |
| `POST /reset` | `{"target": "…"}` |
| `POST /open` | `{"section": "path"}` |
| `POST /settings` | Any of the setting names above |

### Security

- **Loopback only.** The API listens on `127.0.0.1` on a random port. Nothing on your network can reach it.
- **Bearer token.** A new random token is generated at every launch. It is written to `api.json` with mode 0600, so only your user can read it. This also stops web pages in your browser from reaching the API through DNS rebinding or cross-site requests, since they can't know the token.
- **Bounded requests.** Requests over 1 MB are refused.
- **Limited actions.** Write actions cover speed tests, path resets, opening the window and the listed settings. Nothing runs arbitrary commands or reads arbitrary files.

## For development

### Building

```
swift build && swift test              # debug build and unit tests
./scripts/build-app.sh                 # release build/NetMon.app
./scripts/build-app.sh --install       # also install to /Applications, link the CLI, relaunch
```

The install script quits the running app, copies the bundle to `/Applications` (or `~/Applications` if that isn't writable), symlinks `~/.local/bin/netmon` to the binary, and opens the app. It also copies this guide into the bundle for the Guide screen.

`swift run` works for quick iteration, but notifications need the bundled `.app`. A copy run outside the bundle shares the installed app's data folder and overwrites `api.json`. Quit it and relaunch the installed app afterwards.

### Source layout

| Path | Contents |
|---|---|
| `Entry.swift` | Entry point: chooses app, MCP or CLI mode |
| `NetMonApp.swift` | Scenes: menu bar item and main window |
| `AppModel.swift` | App-wide state: monitors and IPv6 twins, history, speed tests, window section |
| `AlertManager.swift` | Alert evaluation and notifications |
| `Preferences.swift` | Settings keys and defaults |
| `Probing/Pinger.swift` | The shared ICMP sockets (one per address family), plus DNS, reverse DNS, routes, IPv6 detection and tunnel detection |
| `Monitoring/TargetMonitor.swift` | Per-target ping, trace and rollup loops; the `Hop` type |
| `Monitoring/PathTracer.swift` | Hop windows and destination confirmation, shared with one-off traces |
| `Monitoring/PathDiagnosis.swift` | The findings rules |
| `Monitoring/Stats.swift` | Statistics, rollups and chart bucketing |
| `Monitoring/Throughput.swift` | `networkQuality` runner |
| `Monitoring/WiFiModels.swift` | Wi-Fi types, channel math, BSS Load parsing, channel load, recommendation and Wi-Fi findings (no CoreWLAN, so testable) |
| `Monitoring/WiFiMonitor.swift` | CoreWLAN reads and scans, Location permission, link sampling, roams and per-minute Wi-Fi history |
| `Monitoring/HistoryStore.swift` | JSON Lines storage |
| `API/` | Loopback HTTP server, routes, client, tool definitions, MCP server, CLI |
| `Views/` | SwiftUI screens |
| `Tests/NetMonTests/` | Diagnosis, tracer, statistics, IPv6 parsing, Wi-Fi and guide tests |

### Concurrency

The model, monitors, alerts and API routes all run on the main actor; their work is small and periodic. Probes complete on the receive thread and resume their async callers. DNS lookups, `networkQuality` and file writes run off the main thread.

### Extending

- **A new finding:** add a rule in `PathDiagnosis.diagnose` and give it a stable `key`, which the alert cooldown uses to recognise repeats. Add a test with a synthetic hop table in `PathDiagnosisTests`.
- **A new tool or command:** add a route in `APIRoutes.handle`, then a `Tool` entry in `Tools.swift`. That entry gives you both the MCP tool and the CLI command. Add argument parsing in `CLI.arguments` if the command takes arguments.
- **A new setting:** add the key and default in `Preferences.swift`, a control in `SettingsView`, and an entry in `SettingsAPI.specs` to expose it over the API.
- **This guide:** edit `docs/HOW-IT-WORKS.md`. The Guide screen renders it, so keep to headings, paragraphs, flat lists, tables, code blocks and inline formatting.
