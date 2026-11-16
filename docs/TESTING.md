# Testing NetMon

Thanks for trying NetMon. It's a menu bar app that watches your internet connection: latency, packet loss and jitter to a few public servers every second. It also traces every router on the way, like mtr, and says which hop is at fault when something goes wrong. Claude Code can read all of it through an MCP server.

This is a test build. It isn't notarized by Apple yet, so macOS needs one extra step to open it.

**Requirements:** a Mac with Apple Silicon and macOS 15 (Sequoia) or later.

## Install

### Option A: the ready-made app

1. Unzip `NetMon-<version>.zip`.
2. In Terminal, run the installer from the unzipped folder:

   ```
   bash ~/Downloads/NetMon-<version>/install.sh
   ```

   It copies NetMon to `/Applications` and clears the download quarantine (needed because the build isn't notarized). It also links the `netmon` command into `~/.local/bin` and starts the app.

If you'd rather not use the script, drag `NetMon.app` to Applications and open it. macOS will refuse the first time. Go to **System Settings › Privacy & Security**, scroll down to the message about NetMon, and click **Open Anyway**.

### Option B: build from source

You need Xcode 16 or later, or the Command Line Tools with Swift 6.

```
unzip netmon-source-<version>.zip -d netmon && cd netmon
swift test                         # optional: runs the unit tests
./scripts/build-app.sh --install   # builds, installs to /Applications, links `netmon`, starts it
```

## What you should see

- A coloured dot and a latency figure in the menu bar: green is healthy, orange degraded, red down, and blue while a speed test runs. Click it for a summary.
- **Open NetMon** (⌘O) opens the full window:
  - **Overview:** latency and loss charts.
  - **Path:** the hop table and the diagnosis.
  - **Throughput:** speed tests.
  - **Events:** a log of alerts, recoveries and speed tests.
  - **Settings.**
  - **Guide:** how everything works, in detail.
- The first alert asks for notification permission.

The Path screen needs about 20 seconds of probing before it gives a diagnosis.

## Using it from Claude Code

The `netmon` command prints JSON:

```
netmon status          # health, latency, loss, findings
netmon path            # hop table and diagnosis
netmon trace github.com
netmon help            # everything else
```

If your shell can't find `netmon`, add `~/.local/bin` to your PATH, or use the full path `/Applications/NetMon.app/Contents/MacOS/NetMon`.

Register the MCP server once, for all your projects:

```
claude mcp add --scope user netmon -- /Applications/NetMon.app/Contents/MacOS/NetMon --mcp
```

Start a **new** Claude Code session, then try asking things like:

- "How's my network connection right now?"
- "Which hop is causing problems?"
- "Was my connection bad in the last 24 hours?"
- "Trace the route to api.github.com"
- "Show me the Path screen"

## Things worth testing

- **Leave it running for a day.** Do alerts fire when the connection really is bad, and stay quiet otherwise?
- **Wi-Fi vs wired, and VPN on vs off.** Does the diagnosis blame the right thing? Through a VPN it should say it's measuring through a tunnel.
- **Speed test.** Click it once to try it. Each run moves hundreds of MB, so mind metered connections. It also runs automatically when an alert fires, at most once an hour; you can turn that off in Settings.
- **Sleep and wake, switching networks.** NetMon should recover by itself. **Reset** on the Path screen clears stale hop data.
- **IPv6.** If your network has IPv6, each target gets an IPv6 twin, marked with an IPv6 badge. Most networks here don't have it, in which case you won't see any twins.

## Reporting problems

Please include:

- What you saw and what you expected.
- The output of `netmon status`, and `netmon path` if it's about the diagnosis. It contains public router addresses and your latency numbers; nothing personal.
- Whether you were on a VPN, Wi-Fi or wired.
- If the app froze: in Terminal, run `sample NetMon 5 -file ~/Desktop/netmon-sample.txt` while it's frozen, and send that file.

## Uninstall

```
pkill -x NetMon
rm -rf /Applications/NetMon.app ~/.local/bin/netmon
rm -rf ~/Library/Application\ Support/NetMon
defaults delete com.babyscripts.netmon
claude mcp remove --scope user netmon
```
