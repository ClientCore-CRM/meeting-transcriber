# Owned-window capture regression

This developer probe creates and records only its own synthetic window, then exits. It is separate from the installable app. Screen Recording permission belongs to the launching app: a Terminal launch may be denied while a Codex launch is authorized. A denied preflight exits 77 and is not a passed capture test.

Build on an unlocked macOS machine with the same production recorder sources:

```sh
swiftc -target arm64-apple-macos14.2 -swift-version 6 -warnings-as-errors -parse-as-library \
  app/MeetingTranscriber/Sources/Boosty/MeetingCaptureClock.swift \
  app/MeetingTranscriber/Sources/Boosty/MeetingWindowRecorder.swift \
  tools/boosty-window-check/main.swift -o /tmp/boosty-window-owned-check
/tmp/boosty-window-owned-check title_idle
/tmp/boosty-window-owned-check static
/tmp/boosty-window-owned-check minimize
/tmp/boosty-window-owned-check close
```

The title-change probe changes blue content to red and asserts that capture ends at the change. It reproduces the two hardware-only failures found during the pilot: repeating the same final PTS can fail H.264 finalization, and ending at the last *updated* frame loses a static interval. The recorder must repeat a safe frame only at a strictly later PTS, using the actual interruption timestamp.

Verified 2026-11-06: all four modes passed with 480×332 H.264 media; every decoded frame was checked and no red replacement frame was present. Minimize/close emitted incomplete-capture warnings. The original final-PTS path failed in two of three live probes before the fix; the static end-time assertion also failed before its fix. This does not replace a real Zoom/Recall pilot.
