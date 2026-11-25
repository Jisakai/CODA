# coda

`coda` is a personal, landscape-only iPad music sketchpad. M0 is a native SwiftUI scaffold: it opens on an edge-to-edge true-black canvas and renders a small Plus Jakarta Sans wordmark. It contains no audio engine, music editing, AI, networking, or microphone access.

## Requirements

- Minimum OS: iPadOS 27.2 on an iPad. The app's interface is limited to landscape left and landscape right.
- Xcode 27.2 with the iOS 27.2 SDK, plus XcodeGen.
- Python 3 for the dependency-free scaffold checks.

The GitHub Actions workflow uses the standard `xcode-27` hosted runner, selects Xcode 27.2 explicitly, and fails if the installed Xcode or iOS SDK version differs.

## Build and test

```sh
brew install xcodegen
xcodegen generate --spec project.yml
python3 -m unittest discover -s Tests/Scaffold -p 'test_*.py' -v
xcodebuild test \
  -project coda.xcodeproj \
  -scheme coda \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.2' \
  CODE_SIGNING_ALLOWED=NO
xcodebuild archive \
  -project coda.xcodeproj \
  -scheme coda \
  -destination 'generic/platform=iOS' \
  -archivePath build/coda.xcarchive \
  CODE_SIGNING_ALLOWED=NO
```

The project is generated from `project.yml`; do not edit or commit `coda.xcodeproj`. XcodeGen is build-only tooling and is not linked into the app. CI records the installed XcodeGen version in the IPA verification report.

The scaffold checks verify the font files' actual PostScript names and `UIAppFonts` registration, iPad-only landscape/full-screen settings, and design-token values. The simulator UI test confirms the app launches and exposes the wordmark. CI additionally archives for a generic iOS device, packages `Payload/coda.app` into `App.ipa`, and checks its Info.plist, arm64 executable, fonts, license, ZIP layout, and SHA-256 before upload.

## Install the unsigned IPA

Download `App.ipa` from the successful workflow artifact and import it into SideStore. Sign and install it through SideStore with your own free Apple account, then refresh it through SideStore before its signing period expires. The archive is intentionally unsigned and carries no provisioning profile or special entitlements.

## M0 scope

M0 delivers only the black launch canvas, bundled Plus Jakarta Sans weights 300/400/500/600/700/800, landscape/full-screen configuration, design tokens, and the unsigned IPA pipeline. Later audio, editing, AI, and project features are not scaffolded here. An actual iPad launch/install check remains an owner-device check after CI produces the artifact.
