#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_binary=$(mktemp -t boosty-account-check)
trap 'rm -f "$check_binary"' EXIT
swiftc -target arm64-apple-macos14.2 -swift-version 6 -warnings-as-errors \
  -module-cache-path "${TMPDIR:-/tmp}/boosty-account-module-cache" -parse-as-library \
  app/MeetingTranscriber/Sources/Boosty/BoostyAPIClient.swift \
  app/MeetingTranscriber/Sources/Boosty/BoostyRecordingState.swift \
  app/MeetingTranscriber/Sources/Boosty/BoostyCredentials.swift \
  app/MeetingTranscriber/Sources/Boosty/BoostyCaptureRoute.swift \
  app/MeetingTranscriber/Sources/Boosty/BoostyConnectionState.swift \
  app/MeetingTranscriber/Sources/Boosty/BoostyExportSnapshot.swift \
  app/MeetingTranscriber/Sources/Boosty/BoostyUploadStore.swift \
  app/MeetingTranscriber/Sources/Boosty/BoostyUploadQueue.swift \
  app/MeetingTranscriber/Sources/Boosty/MeetingWindowRecorder.swift \
  app/MeetingTranscriber/Sources/Boosty/MeetingURLReader.swift \
  app/MeetingTranscriber/Sources/Boosty/MeetingCaptureClock.swift \
  app/MeetingTranscriber/Sources/Boosty/MeetingMediaAssembler.swift \
  app/MeetingTranscriber/Sources/Boosty/BoostyExportBuilder.swift \
  app/MeetingTranscriber/Sources/Boosty/BoostyFileHash.swift \
  tools/boosty-account-checks/main.swift -o "$check_binary"
"$check_binary"
