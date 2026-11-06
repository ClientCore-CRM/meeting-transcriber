# Boosty desktop pilot

This fork preserves local MeetingTranscriber processing and adds optional storage in Boosty. MIT and upstream notices remain applicable.

Connect your own account in Settings → Boosty. The browser asks you to approve the installation and account. Credentials are stored in macOS Keychain. Enable upload only for an installation running the matching desktop-import API.

New recordings send a bot-cancellation request immediately. An exact meeting URL identifies the calendar occurrence; when that URL cannot be read reliably, choose the calendar meeting in Settings → Boosty. Bot cancellation remains explicitly unconfirmed until the server confirms it. Never infer cancellation from the local recording indicator.

Only the selected meeting window is captured. Screen Recording permission is required; ambiguous windows require selection. The app does not substitute the display if the window closes. Incomplete video and missing summary remain visible. Audio and transcription use existing local settings.

The durable upload queue keeps immutable media copies, resumes missing 8 MiB parts, and stays bound to the account that started recording. Late speaker naming creates a new source revision. Boosty stores supplied results without ASR or LLM processing. Existing library recordings are not uploaded automatically. Record-only recordings stay record-only.

Pilot builds are ad-hoc signed, not notarized. Full live verification (scheduled bot, joined bot, video/audio alignment and restart during upload) is required before distributing to employees.

Inherited publishing, release, automation and scheduled workflows are archived with `.disabled` suffixes in this pilot branch. The only active workflow runs tests and produces a private-to-the-run build artifact; it does not publish a release or deploy.

Window identity is checked before accepting video frames: window ID, owner PID and title must remain unchanged. A title change or missing identity ends video and marks the import incomplete; audio continues. Use a dedicated meeting window for browser calls. Live browser/tab/minimize behavior must still be checked on an unlocked Mac.

The audio/video timebase comes from actual first-buffer hardware timestamps propagated by AudioTapLib. Interrupted recordings without a verified audio origin omit video rather than shift the transcript. An unreadable movie cannot block the audio, transcript or summary import.

Verification: full app XCTest and packaging passed on Xcode 27.0 in [pilot CI](https://github.com/ClientCore-CRM/meeting-transcriber/actions/runs/42229832786). The downloaded arm64 DMG passed image checksum/signature checks and its bundled synthetic audio self-test on the target Mac. Actions is disabled again and the default branch is main. Real meeting/window acceptance remains tracked in Multica XNA1D-662.

Hardware follow-up: on an unlocked Mac, actual owned-window capture, static-window finalization, title-change interruption, minimize and close probes passed. Finalization now avoids duplicate PTS and preserves static intervals. All decoded test frames exclude red replacement content. The final local pilot DMG includes this two-line hardware fix; the earlier full Xcode CI covered the preceding code, and the fix was verified by actual capture plus full local builds, lint and media probes. A real Zoom/Recall/second-account pilot is still required before employee distribution.

## Summary provider

Settings → Output → LLM Provider supports **Codex CLI** and **Claude CLI**, as well as the existing OpenAI-compatible API and transcript-only mode. Select Codex CLI and an installed binary to use an existing `codex login` session. No Claude installation is needed. The app also discovers the CLI bundled with ChatGPT for macOS.

Codex runs non-interactively in a private temporary directory, with read-only sandboxing, user configuration/rules and session persistence disabled. Shell, browser, computer, plugin and multi-agent features are disabled. The transcript goes through stdin; only the final Markdown response is imported. Temporary input/output files are removed after success, failure or cancellation. Diagnostic output is discarded to avoid exposing meeting content. Failures preserve the transcript for retry. Use a recent Codex CLI supporting `exec --ignore-user-config`.

Speech recognition remains local; the selected summary provider receives the transcript. Codex uses its current account/model defaults rather than an API key stored by this app.
