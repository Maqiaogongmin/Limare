# Third-Party Licenses

Limare is licensed under the GNU General Public License v3.0 (see `LICENSE`). It is
derived from OpenMinis and bundles, links, vendors or adapts the components below.
Versions reflect the current source tree. License types were read from each
component's LICENSE file in its resolved package checkout, its vendored copy, or the
notice its packaging script embeds, unless the row says otherwise.

## Upstream project

| Project | What Limare uses | License |
|---|---|---|
| [OpenMinis](https://github.com/OpenMinis/OpenMinis), by the OpenMinis authors | Limare started as a fork of OpenMinis at `4ef2900` (tag `1.13`). `deps/OpenMinisProviders` is an adapted extraction of `src/ios/Providers`; `SOURCE-LINEAGE.json` lists each original file, its SHA-256 at upstream `4f9af96` and the adaptations. Code ported from OpenMinis says so in its comments (e.g. `Services/OpenAIStreamParser.swift`; the tokenizer verifier and its `cl100k_base.tiktoken` vocabulary under `script/`). | **GPL-3.0** |

## Vendored source

| Component | Version / Location | License |
|---|---|---|
| [MarkdownView](https://github.com/Lakr233/MarkdownView) (Lakr233) | 4.8.2, `deps/MarkdownView` (Limare changes listed in its README) | **MIT** (`deps/MarkdownView/LICENSE`) |
| [markdown-it](https://github.com/markdown-it/markdown-it) | 15.0.2, `src/macos/RemoteWeb/vendor/` (Remote Access web UI) | **MIT** (`markdown-it.LICENSE` alongside) |

## Adapted text

| Source | Where | License text |
|---|---|---|
| [opencode](https://github.com/anomalyco/opencode): default system prompt, environment block and instruction-file lookup, adapted where opencode names itself, its CLI or its tools | `src/macos/Limare/Services/CodingAgentPrompt.swift` | **MIT**, Copyright (c) 2025 opencode — [`LICENSES/opencode-MIT.txt`](LICENSES/opencode-MIT.txt) (from `anomalyco/opencode` `LICENSE` at `ef3fd5900fd3`) |
| [Codex](https://github.com/openai/codex): planning instructions (adapted), `update_plan` tool description texts (unchanged), `spawn_agent` delegation guidance (changed to Limare's tool names) | `CodingAgentPrompt.swift` ("# Planning"), `src/macos/Limare/Models/ChatMessage.swift`, `src/macos/Limare/Stores/ConversationRunCoordinator.swift` | **Apache-2.0**, Copyright 2025 OpenAI — [`LICENSES/codex-Apache-2.0.txt`](LICENSES/codex-Apache-2.0.txt) and its NOTICE [`LICENSES/codex-NOTICE.txt`](LICENSES/codex-NOTICE.txt) (from `openai/codex` `LICENSE` at `59a180ddec4a`, `NOTICE` at `8a559e7938bd`) |
| [Codex](https://github.com/openai/codex): macOS Seatbelt base policy (`codex-rs/sandboxing/src/seatbelt_base_policy.sbpl`, unchanged text) inherited by Agent shell and MCP stdio children; Limare appends its own workspace/temp write, network and reserved-path rules | `src/macos/Limare/Services/MCPExecutionPolicy.swift` | **Apache-2.0**, Copyright 2025 OpenAI — [`LICENSES/codex-Apache-2.0.txt`](LICENSES/codex-Apache-2.0.txt) and its NOTICE [`LICENSES/codex-NOTICE.txt`](LICENSES/codex-NOTICE.txt) (policy, `LICENSE` and `NOTICE` identical at `092d3acd6bec`) |

Each adapted file names its source and license in a comment next to the adapted text.
Other comments that mention Claude Code, Codex or opencode describe behaviour Limare models
on those tools; no text is copied there.

## Bundled helpers

| Helper | Version | Packaged by | License |
|---|---|---|---|
| [cua-driver](https://github.com/trycua/cua) | 0.28.2, `Contents/Helpers/cua-driver` | `script/package_cua_driver.sh` (pinned, SHA-256 verified); license shipped as `Contents/Resources/CUA_DRIVER_LICENSE.txt` | **MIT** |
| [cloudflared](https://github.com/cloudflare/cloudflared) | 2026.10.0, `Contents/Helpers/cloudflared` | `script/package_cloudflared.sh` (pinned, SHA-256 verified); license shipped as `Contents/Resources/CLOUDFLARED_LICENSE.txt` | **Apache-2.0** |

## Swift packages

Locked by `src/macos/Limare.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

| Package | Version | Pulled in by | License |
|---|---|---|---|
| [Vapor](https://github.com/vapor/vapor) | 4.122.2 | Limare (Remote Access) | **MIT** |
| [jwt-kit](https://github.com/vapor/jwt-kit) | 5.7.1 | Limare (Remote Access) | **MIT** |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 2.10.0 | Limare (manual updates) | **MIT and bundled component notices**, included in the pinned checkout and app Credits |
| [AppAuth-iOS](https://github.com/openid/AppAuth-iOS) | 3.0.0 | Limare (provider sign-in) | **Apache-2.0** |
| [SwiftAnthropic](https://github.com/jamesrochabrun/SwiftAnthropic) | 2.2.2 | OpenMinisProviders | **MIT**, included in the pinned checkout — [`LICENSES/SwiftAnthropic-MIT.txt`](LICENSES/SwiftAnthropic-MIT.txt) |
| [Litext](https://github.com/Lakr233/Litext) | 3.6.1 | MarkdownView | **MIT** |
| [DisplayLink](https://github.com/Lakr233/DisplayLink) | 3.0.1 | Litext | **MIT** |
| [LRUCache](https://github.com/nicklockwood/LRUCache) | 1.3.0 | MarkdownView | **MIT** |
| [SwiftMath](https://github.com/mgriebling/SwiftMath) | 1.7.3 | MarkdownView | **MIT** |
| [swift-cmark](https://github.com/swiftlang/swift-cmark) | 0.9.0 | MarkdownView | **BSD-2-Clause** (with some MIT-licensed vendored files, see its `COPYING`) |
| [mcp-swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) | 0.12.1 + six upstream PRs, vendored in [`deps/swift-sdk`](deps/swift-sdk/README.md) (one Limare change listed there) | Limare (MCP runtime) | **Apache-2.0 / MIT** — [`deps/swift-sdk/LICENSE`](deps/swift-sdk/LICENSE) |
| [eventsource](https://github.com/mattt/eventsource) | 1.5.1 | mcp-swift-sdk | **MIT** |

**SwiftAnthropic.** Version 2.2.2, revision `b7d030cd7453f314c780f5492385f73d704cbd5d`, includes an explicit MIT LICENSE in its own source tree. The bundled notice is taken from that checkout; the earlier 2.2.0 license ambiguity no longer applies to this candidate.

Vapor's own packages `routing-kit`, `console-kit`, `websocket-kit`, `multipart-kit`,
`async-kit` (**MIT**); Apple / Swift Server Workgroup packages `async-http-client`,
`swift-collections`, `swift-configuration`, `swift-nio` (+ `-extras`, `-http2`, `-ssl`,
`-transport-services`), `swift-crypto`, `swift-certificates`, `swift-asn1`, `swift-log`,
`swift-metrics`, `swift-distributed-tracing`, `swift-service-context`,
`swift-service-lifecycle`, `swift-http-types`, `swift-http-structured-headers`,
`swift-algorithms`, `swift-async-algorithms`, `swift-atomics`, `swift-numerics`,
`swift-system` (**Apache-2.0**).

## Notices in the app bundle

The build phase `script/bundle_notices.py` writes `Contents/Resources/Credits.html`, shown by
Limare > About Limare. It holds Limare's GPL-3.0 text and the license and NOTICE files of every
component above: the vendored packages in `deps/` (`deps/OpenMinisProviders/LICENSE` is the
OpenMinis GPL-3.0 file), every Swift package pinned in `Package.resolved` (read from its
checkout), the adapted texts in `LICENSES/`, the bundled helpers and the Remote Access web
vendor files. A component without a license file fails the build. The helpers' licenses and
`RemoteWeb/vendor/markdown-it.LICENSE` also stay next to the files they cover.

## Removed / historical

- The OpenMinis iOS and Android apps and their native and platform dependencies (iSH,
  PRoot, FFmpeg, LAME, talloc, rclone, cppjieba, KaTeX, the Alpine rootfs scripts, the
  Android Gradle libraries and the iOS-only Swift packages) were removed from this
  repository on 2026-10-09 and are no longer part of Limare. Their notices remain
  upstream.
- **swift-markdown-ui** (MIT) — formerly vendored under `deps/swift-markdown-ui`; no
  longer referenced by the Xcode project or imported by any source file.
