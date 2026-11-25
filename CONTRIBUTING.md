# Contributing to NetMon

Thanks for helping. Bug reports, fixes and well-scoped features are all welcome.

## Before you start

For anything bigger than a small fix, open an issue first so we can agree on the approach. NetMon tries to stay small: no dependencies, no root, and nothing leaves the Mac except the measurements themselves.

## Building and testing

You need macOS 15 or later on Apple Silicon, and Xcode 16 or later (or the Command Line Tools with Swift 6).

```bash
swift build && swift test           # build and run the unit tests
./scripts/build-app.sh              # build build/NetMon.app (ad-hoc signed)
./scripts/build-app.sh --install    # also install to /Applications, link `netmon`, and launch
```

`swift run` works for quick iteration, but notifications and Location Services only work from the bundled `.app`. Ad-hoc signed builds look like a new app to macOS after every rebuild, so it may ask for Location permission again.

[docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md) explains the measurement, the diagnosis rules and the source layout. Read the section for the area you're changing first.

## Pull requests

- Keep each PR to one change, and explain why it's needed, not only what it does.
- Add or update tests for logic changes. Diagnosis rules, channel maths and parsing live in pure types (for example `PathDiagnosis` and `WiFiAnalysis`) so they can be tested without a network.
- Match the style of the surrounding code. The project uses the Swift 6 toolchain in Swift 5 language mode.
- If you change behaviour a user can see, update `docs/HOW-IT-WORKS.md` (it's also the in-app Guide) and the README where relevant.
- If you add or change an MCP tool or CLI command, edit `Sources/NetMon/API/Tools.swift`; MCP and the CLI are generated from it.
- `swift test` must pass. CI runs it on every pull request.

## Privacy

NetMon reads sensitive context: router addresses, Wi-Fi network names and access point addresses. Keep it on the Mac. Don't add analytics, crash reporting or any network call beyond the probes. When you post output in an issue, remove Wi-Fi names and access point addresses (BSSIDs), which can reveal where you are.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
