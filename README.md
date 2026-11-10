# Replies

A native macOS app that reads your own iMessage history and shows you how you actually reply —
response times, who you leave on read, which threads you start, and how your tone shifts by contact.

Built in Swift with no third-party dependencies. Everything stays on the machine: the app reads the
local `chat.db` directly and never sends a message, a contact or a byte anywhere.

## Why I built it

I wanted a real answer to "am I bad at texting people back, or does it just feel that way."
The data was already on my Mac; nothing read it.

## How it works

- **Reader** — opens the local iMessage SQLite store read-only and decodes `attributedBody`
  (Apple stores modern message text as an archived blob, not plain text, which is the part
  most scripts get wrong).
- **Stats** — response-time distributions, thread initiation ratios, streaks, per-contact rollups.
- **App** — SwiftUI front end over the stats layer.

## Running it

```sh
./build-app.sh      # builds Replies.app
swift test          # unit tests run against a synthetic fixture database
```

macOS will ask for Full Disk Access the first time, because that is what reading `chat.db` requires.

## Privacy

No network calls. No analytics. The test fixtures in this repo are synthetic — my own
message database is gitignored and has never been committed.

## Stack

Swift, SwiftUI, SQLite, XCTest. Built and tested on macOS 15.
