# Boosty desktop pilot

This fork preserves local MeetingTranscriber processing and adds optional storage in Boosty. MIT and upstream notices remain applicable.

Connect your own account in Settings → Boosty. The browser asks you to approve the installation and account. Credentials are stored in macOS Keychain. Enable upload only for an installation running the matching desktop-import API.

New recordings send a bot-cancellation request immediately. An exact meeting URL identifies the calendar occurrence; when that URL cannot be read reliably, choose the calendar meeting in Settings → Boosty. Bot cancellation remains explicitly unconfirmed until the server confirms it. Never infer cancellation from the local recording indicator.

Only the selected meeting window is captured. Screen Recording permission is required; ambiguous windows require selection. The app does not substitute the display if the window closes. Incomplete video and missing summary remain visible. Audio and transcription use existing local settings.

The durable upload queue keeps immutable media copies, resumes missing 8 MiB parts, and stays bound to the account that started recording. Late speaker naming creates a new source revision. Boosty stores supplied results without ASR or LLM processing. Existing library recordings are not uploaded automatically. Record-only recordings stay record-only.

Pilot builds are ad-hoc signed, not notarized. Full live verification (scheduled bot, joined bot, video/audio alignment and restart during upload) is required before distributing to employees.

Inherited publishing, release, automation and scheduled workflows are archived with `.disabled` suffixes in this pilot branch. The only active workflow runs tests and produces a private-to-the-run build artifact; it does not publish a release or deploy.
