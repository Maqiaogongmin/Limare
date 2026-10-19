# Limare

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

**A native macOS AI agent harness.**

Limare is a SwiftUI app for macOS that runs a coding and general-purpose agent
on your Mac: bring your own model providers, give the agent a shell, files, a
browser, Computer Use, skills, MCP servers, hooks and persistent memory, and
work in projects and conversations. It can also be reached from a phone through
Remote Access.

## Download

Version **0.1.3** targets **Apple Silicon (`arm64`) and macOS 15.0+**.
Download the signed, notarized DMG from [GitHub Releases](https://github.com/Maqiaogongmin/Limare/releases/latest).
The matching source is available with each release. Intel is outside this scope.

Limare uses local-first storage and user-controlled credentials, including API
keys, supported third-party OAuth, and provider-issued credentials. Models,
MCP, browser sessions, Hooks, Computer Use, speech, and Remote Access can send
data to the services you select. The developer operates no model relay or
conversation storage backend. The main app does not use Apple App Sandbox.

Read the [privacy policy](https://limare.app/privacy/),
[security guidance](SECURITY.md), and [support information](SUPPORT.md).
Updates are checked only when you choose **Limare > Check for Updates…**;
there are no background checks or silent installations. Credentials have
separate storage boundaries: Provider and Remote Access credentials use
permission-restricted local files, while production MCP credentials use Keychain.

---

## Building

See [BUILDING.md](BUILDING.md). In short, with Xcode 27:

```sh
script/build_and_run.sh
```

---

## Repository layout

```
src/macos/Limare.xcodeproj   Xcode project (scheme and app target: Limare)
src/macos/Limare/            The app: App, Models, Services, Stores, Views, Resources
src/macos/LimareTests/       XCTest unit tests
src/macos/LimareUITests/     XCUITest GUI verification
src/macos/RemoteWeb/         Web UI served by Remote Access
deps/MarkdownView/           Vendored message renderer (MIT, see its README)
deps/OpenMinisProviders/     Provider protocol code extracted from OpenMinis (see below)
script/                      Build, export, signing and verification tools
LICENSES/                    License texts of adapted third-party code (see THIRD_PARTY_LICENSES.md)
website/                     Product page
```

---

## Origin and acknowledgements

Limare is derived from **[OpenMinis](https://github.com/OpenMinis/OpenMinis)**,
the open-source mobile AI agent by the OpenMinis authors, licensed under the
GNU General Public License v3.0. This repository started as a fork of
OpenMinis at upstream commit `4ef2900` (tag `1.13`). The macOS app was then
written in this tree, reusing and adapting parts of OpenMinis:

- `deps/OpenMinisProviders` is an extraction of the OpenMinis provider sources
  (`src/ios/Providers`). `SOURCE-LINEAGE.json` records the upstream commit, the
  SHA-256 of each original file and every adaptation.
- Some app code is ported from OpenMinis and says so in its comments, for
  example `Services/OpenAIStreamParser.swift`.

The OpenMinis iOS and Android apps and their native dependencies were removed
from this repository on 2026-10-09; they remain available upstream.

Limare also uses or adapts other open-source work; the inventory, with versions
and license terms, is in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

---

## License

Limare is licensed under the **[GNU General Public License v3.0](LICENSE)**, the
license of the OpenMinis code it is derived from. Third-party licenses are
listed in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
