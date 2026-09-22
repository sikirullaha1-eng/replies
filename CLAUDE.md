# Replies — project notes

A Mac app that reads Sikiru's own iMessage history and analyses how he replies.
Read-only, offline, no dependencies.

## How it is built — there is no Xcode on this Mac
Only Command Line Tools are installed, so there is no `.xcodeproj` and
`xcodebuild` does not work. `build-app.sh` does the whole job:

1. `swiftc -O -parse-as-library $(find Sources -name '*.swift')` → one binary
2. hand-assembles `Replies.app/Contents/{MacOS,Info.plist,Resources}`
3. ad-hoc signs it with `codesign --force --deep --sign -`

Sources are NESTED (`Sources/Store/`, `Sources/Views/`…), so the script gathers
them with `find`, not a flat `Sources/*.swift` glob. No file is named
`main.swift`, which is why `-parse-as-library` is required.

Build and run:

    ./build-app.sh && open Replies.app

## Full Disk Access — the one wall
macOS refuses `~/Library/Messages/chat.db` to any process without Full Disk
Access. Confirmed: a plain terminal read returns `authorization denied`. The
grant is per-app, so `Replies.app` itself must be added in
System Settings → Privacy & Security → Full Disk Access. Until then the app
falls back to `fixtures/sample-chat.db`.

That also means **the agent cannot read his real messages from a terminal.**
Every test in this project runs against the generated fixture.

## Layout
- `Sources/RepliesApp.swift` — `@main`, the window
- `Sources/AppState.swift` — `@Observable` shared state (`LoadPhase`, `DataSource`)
- `Sources/Views/` — all SwiftUI
- `Sources/Store/` — the chat.db reader (RPL-2)
- `Sources/Analysis/` — the statistics (RPL-4)
- `Sources/Intelligence/` — on-device FoundationModels style read (RPL-5)
- `Tools/make-fixture.swift` — writes `fixtures/sample-chat.db`
- `run-tests.sh` — the checks; takes a suite name (`store`, `analysis`, …)

## Things to know before touching the data layer
- Apple stores message dates as **nanoseconds since 2001-01-01**.
  `seconds = date/1e9 + 978307200`. Very old rows are in plain seconds —
  check the magnitude before converting.
- `message.text` is often NULL on modern macOS; the body lives in
  `attributedBody` as an archived `NSAttributedString`. A reader that ignores
  it silently loses a large share of the history.
- Open with `sqlite3_open_v2(..., SQLITE_OPEN_READONLY)` and an `immutable=1`
  file URI, so a WAL lock held by Messages cannot block the read.

## The user
Sikiru — a beginner. Explain in plain language and give him ONE command at a
time to run.
