# Building Limare

Limare is one Xcode project, `src/macos/Limare.xcodeproj`, with the scheme and
app target `Limare`. It needs macOS and Xcode 27 on Apple silicon.

## Dependencies

- Swift packages are locked by the committed
  `src/macos/Limare.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
  Build with `-onlyUsePackageVersionsFromResolvedFile` so a stale package cache
  cannot change them.
- Three local packages live in `deps/`: `MarkdownView` (vendored renderer),
  `OpenMinisProviders` (provider protocol code extracted from OpenMinis), and
  `swift-sdk` (vendored MCP SDK).
- Sparkle 2.10.0 is pinned for manual update checks. Its public EdDSA key is
  bundled; the private key is kept in the release operator's Keychain.
- The build phase runs `script/build_helper.sh`, which places two pinned,
  checksum-verified helpers in `dist/`: `cua-driver` (Computer Use) and
  `cloudflared` (Remote Access). Their licenses are copied into the app's
  Resources.
- A second build phase runs `script/bundle_notices.py`, which writes the license
  and NOTICE texts of Limare and every shipped component into
  `Contents/Resources/Credits.html` (shown by Limare > About Limare). The build
  fails if a component has no license file; keep a missing one in `LICENSES/`
  as `<package identity>-<license>.txt`.

## Build and run

```sh
script/build_and_run.sh            # signed Debug build into .build/, then launch
script/build_and_run.sh --unsigned # build without signing
```

Or directly:

```sh
xcodebuild \
  -project src/macos/Limare.xcodeproj \
  -scheme Limare \
  -configuration Debug \
  -derivedDataPath /tmp/limare-derived \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO build
```

## Install

For public releases, mount the signed/notarized DMG and drag Limare.app into
Applications. Development builds and helper ad-hoc signatures are not public
release artifacts.

Release operators use Xcode Archive and Developer ID export from the final
candidate's clean clone, followed by `script/sign_release_bundle.py` and
`script/verify_release_bundle.py`. A matching Developer ID certificate and
distribution profile are required. Notarize and staple the final DMG, then
calculate its SHA-256 and Sparkle EdDSA signature. See `release-facts.json` for
the frozen product facts. Private keys and provisioning profiles are not
included in source.

## Data

The app keeps its data in `~/Library/Application Support/app.limare.Limare` and
its caches in `~/Library/Caches/app.limare.Limare`. Test runners and XCTest
hosts never use those folders (see `src/macos/Limare/App/LimareStorage.swift`).

## Tests

- Provider protocol tests: `swift test --package-path deps/OpenMinisProviders`.
- `LimareTests` and `LimareUITests` run through the `Limare` scheme in Xcode.
  Live service tests require explicit `LIMARE_LIVE=1` and user credentials;
  their absence is a skipped live check, not a successful live acceptance.
