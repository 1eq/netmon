# Releasing NetMon

Pushing a tag like `v0.2.0` runs [.github/workflows/release.yml](../.github/workflows/release.yml), which:

1. runs the tests,
2. builds the app and signs it with the Developer ID certificate under the hardened runtime,
3. notarizes it with Apple and staples the ticket,
4. publishes a GitHub release with `NetMon-<version>.zip` and generated notes,
5. writes the new cask to `Casks/netmon.rb` in [1eq/homebrew-tap](https://github.com/1eq/homebrew-tap), so `brew upgrade` picks it up.

A tag with a suffix (`v0.3.0-beta.1`) is published as a pre-release and skips the tap.

## Cutting a release

```bash
git switch main && git pull
git tag -a v0.2.0 -m "NetMon 0.2.0"
git push origin v0.2.0
```

Then watch the run under **Actions**. Notarization usually takes 1–5 minutes.

## One-time setup

The Developer ID certificate signs apps as the company. Anyone who can run a job with it can ship software that macOS trusts as ours, and if it leaks Apple revokes it, which breaks every app signed with it. So lock the environment down **before** adding any secret:

1. **Create the environment.** In **Settings › Environments**, add one named `release`. Put all the secrets below there, never in repo-wide secrets.
2. **Require reviewers.** Under **Required reviewers**, name one or two maintainers and turn on **Prevent self-review**. Every release run then waits for a second person's approval before it can read the secrets.
3. **Restrict to release tags.** Under **Deployment branches and tags**, choose **Selected branches and tags** and add only the tag rule `v*`. A workflow on a branch, including an edited one, can't use the environment.
4. **Protect the tags.** In **Settings › Rules › Rulesets**, add a tag ruleset for `v*` that restricts creation, update and deletion to the maintainers.
5. **Keep write access small.** Contributors work from forks; workflows from fork pull requests never get secrets.
6. **Pin third-party actions.** The workflow uses only `actions/checkout`. If you add another action, pin it to a full commit SHA.

Rotate the `.p12` password and the App Store Connect key if anyone with access leaves.

| Secret | What it is |
|---|---|
| `DEVELOPER_ID_CERT_P12` | The **Developer ID Application** certificate and its private key, exported from Keychain Access as `.p12`, then base64-encoded: `base64 -i cert.p12 \| pbcopy` |
| `DEVELOPER_ID_CERT_PASSWORD` | The password you set when exporting the `.p12` |
| `NOTARY_API_KEY_P8` | An App Store Connect API key (**Users and Access › Integrations › App Store Connect API**, role Developer), base64-encoded: `base64 -i AuthKey_XXXX.p8 \| pbcopy` |
| `NOTARY_API_KEY_ID` | That key's ID |
| `NOTARY_API_ISSUER_ID` | The issuer ID shown above the keys list |
| `HOMEBREW_TAP_TOKEN` | A fine-grained personal access token (or GitHub App token) with **Contents: read and write** on `1eq/homebrew-tap` only |

The Developer ID certificate must belong to the Apple team whose name users will see in Gatekeeper. Only the team's Account Holder can create one.

## Signing a build locally

```bash
SIGN_IDENTITY="Developer ID Application: Example, Inc. (TEAMID)" VERSION=0.2.0 ./scripts/build-app.sh
```

A signed build keeps a stable identity across rebuilds, so macOS stops asking for Location permission again.
