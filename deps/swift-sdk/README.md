# MCP Swift SDK (vendored, pinned)

Limare's MCP runtime: [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk)
**0.12.1** (`a0ae212ebf6eab5f754c3129608bc5557637e605`) plus six upstream pull requests that
were open and unmerged on 2026-10-12, merged unchanged. The upstream repository has had no
release or push since 2026-05-07, and these fixes are what the construction blueprint's §4 gate
needs for stdio and Streamable HTTP. Licensed as upstream (see `LICENSE`).

| PR | Head commit | Fix |
|---|---|---|
| [#266](https://github.com/modelcontextprotocol/swift-sdk/pull/266) | `044e2b31f11714901a2b4a0b2f6f73098a757aca` | stdio frames no longer interleave under backpressure |
| [#275](https://github.com/modelcontextprotocol/swift-sdk/pull/275) | `8e36cfac72722e2e0bb84dcfc013cd1c08ecd898` | client message loop ends when the transport stream finishes |
| [#293](https://github.com/modelcontextprotocol/swift-sdk/pull/293) | `c5374dbd283df71eb4f6548c30016ed8c9282c15` | OAuth issuer and registration metadata validation |
| [#296](https://github.com/modelcontextprotocol/swift-sdk/pull/296) | `68705a2865b8d94ab15953483c283fdd7463f1d9` | standalone SSE resume IDs kept apart from POST responses |
| [#297](https://github.com/modelcontextprotocol/swift-sdk/pull/297) | `f2d760c7aed0a5ed25daacd0c3a051d5ea153f33` | stdio descriptor flags restored on disconnect |
| [#298](https://github.com/modelcontextprotocol/swift-sdk/pull/298) | `25a7a6f151818ee4a33f635d978f291ae30af252` | HTTP requests kept separate during cancellation |

Merged in that order onto tag 0.12.1. The only manual step: #297 and #266 both add stored
properties at the same place in `StdioTransport.swift`; both sets are kept. Git merged the
rest (#266's serialized `send`, #297's drain counter in `write`) without conflict.
Resulting `Sources/MCP` tree: `7171094b1eef1c7a21f1afec76562827fcf6f69e`.

Only `Sources/MCP` and `Tests/MCPTests` are kept, and `Package.swift` is trimmed to the
`MCP` library and its tests (no conformance executables, swift-nio or docc plugin); the
dependency requirements are upstream's. swift-system, swift-log and eventsource come from their
remotes, locked by `src/macos/Limare.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
`swift test` here runs upstream's 579 tests; all pass.

## Limare changes

1. **The session initializer of `HTTPClientTransport` is public** (was `internal`), unchanged
   otherwise. Limare passes its own ephemeral `URLSession` whose delegate refuses redirects and
   implicit credentials, so a configured `Authorization` header never follows a redirect to another
   host (blueprint §4 item 5, §10). The public `configuration:` initializer cannot express that.
   File: `Sources/MCP/Base/Transports/HTTPClientTransport.swift`.

OAuth is present but unused: Limare does not admit SDK OAuth in this phase.

## Leaving the fork

When an official release contains these fixes and passes the blueprint's §4 gate, depend on that
tag again and delete this directory.
