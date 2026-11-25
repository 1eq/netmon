# Security policy

## Reporting a vulnerability

Please don't open a public issue for security problems. Report them privately through GitHub: on the repository's **Security** tab, click **Report a vulnerability**. Only the maintainers can see the report.

Include what you found, how to reproduce it, and the NetMon version (the `version` field of `netmon status`). We aim to reply within a week.

## What's in scope

NetMon runs without root and keeps everything on your Mac. The parts most worth scrutiny:

- **The local API.** The app serves its data on `127.0.0.1` only, behind a random bearer token that is regenerated at each launch and stored in `~/Library/Application Support/NetMon/api.json` with mode `0600`. Ways to reach it from another user account, a web page or a remote host are in scope.
- **The MCP server and CLI**, which read that token and call the API.
- **Settings changes through the API**, which are range-checked. Ways to bypass the checks are in scope.
- **Anything that sends data off the Mac** beyond the ICMP probes, the trace probes and Apple's `networkQuality` test. NetMon shouldn't.

Bugs in macOS itself, or in `networkQuality`, should go to Apple.

## Supported versions

Only the latest release gets fixes.
