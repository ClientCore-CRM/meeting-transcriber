import SwiftUI

struct BoostySettingsView: View {
    @Bindable var connection = BoostyConnectionState.shared
    @Bindable var uploads = BoostyUploadQueue.shared

    var body: some View {
        Form {
            Section("Boosty account") {
                TextField("Installation address", text: $connection.origin)
                    .disabled(connection.credential != nil || connection.isConnecting)
                Text(connection.status).textSelection(.enabled)
                if connection.credential == nil {
                    Button("Connect in browser") { connection.connect() }
                        .disabled(connection.isConnecting)
                } else {
                    Toggle("Automatically upload new recordings", isOn: $connection.uploadEnabled)
                    Button("Disconnect") { Task { await connection.disconnect() } }
                }
            }
            Section("Uploads") {
                if let error = uploads.storageError { Text(error).foregroundStyle(.red) }
                if uploads.entries.isEmpty { Text("No recordings queued for Boosty.").foregroundStyle(.secondary) }
                ForEach(Array(uploads.entries.suffix(8).reversed())) { entry in
                    BoostyUploadEntryView(entry: entry, uploads: uploads)
                }
            }
            Section {
                Text(
                    "New recordings are transcribed on this Mac. Boosty stores the finished transcript, speaker names, summary and meeting-window video. "
                        + "Starting a local recording cancels the bot for the selected meeting.",
                )
                .foregroundStyle(.secondary)
                Text("Existing recordings are not uploaded automatically.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct BoostyUploadEntryView: View {
    let entry: BoostyUploadEntry
    let uploads: BoostyUploadQueue
    @State private var selected = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.title).font(.headline)
            Text(entry.status).textSelection(.enabled)
            Text("Bot: " + entry.botStatus).font(.caption).foregroundStyle(.secondary)
            if !entry.candidates.isEmpty && entry.selectedMeetingId == nil && !entry.skipCalendarSelection {
                Text("Select the calendar meeting so Boosty can cancel its bot. Recording continues locally.")
                    .font(.caption)
                Picker("Meeting", selection: $selected) {
                    Text("Choose a meeting…").tag("")
                    ForEach(entry.candidates) { meeting in Text(meeting.title).tag(meeting.id) }
                }
                HStack {
                    Button("Cancel bot for this meeting") { uploads.selectMeeting(entry.id, meetingId: selected) }.disabled(selected.isEmpty)
                    Button("No matching calendar meeting") { uploads.selectMeeting(entry.id, meetingId: nil) }
                }
            }
            HStack {
                Button("Retry") { uploads.retry(entry.id) }
                if let path = entry.receiptURL, path.hasPrefix("/calls/"), let url = URL(string: entry.origin + path) {
                    Link("Open in Boosty", destination: url)
                }
            }
        }
        .padding(.vertical, 6)
    }
}
