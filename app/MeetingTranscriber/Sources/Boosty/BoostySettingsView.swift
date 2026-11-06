import SwiftUI

struct BoostySettingsView: View {
    @Bindable var connection = BoostyConnectionState.shared
    @Bindable var uploads = BoostyUploadQueue.shared
    @State private var addingAccount = false

    var body: some View {
        Form {
            accountsSection
            connectionSection
            uploadsSection
            explanationSection
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: connection.credential?.deviceId) { _, _ in addingAccount = false }
    }

    private var accountsSection: some View {
        Section("Boosty accounts") {
            ForEach(connection.accounts) { account in
                Button {
                    connection.selectAccount(account.id)
                } label: {
                    Label(
                        "\(account.company) — \(account.email)",
                        systemImage: account.id == connection.credential?.accountKey ? "checkmark.circle.fill" : "circle",
                    )
                }
                .disabled(connection.isConnecting)
            }
            Text(connection.status).textSelection(.enabled)
            if connection.credential != nil {
                Toggle("Automatically upload new recordings for this account", isOn: $connection.uploadEnabled)
                Button("Disconnect this account") { Task { await connection.disconnect() } }
            }
            if !addingAccount && connection.credential != nil {
                Button("Add another account") {
                    connection.origin = connection.credential?.origin == "https://meets.clientcore.ru"
                        ? "https://boosty.retailrocket.ru" : "https://meets.clientcore.ru"
                    addingAccount = true
                }
            }
        }
    }

    @ViewBuilder private var connectionSection: some View {
        if addingAccount || connection.credential == nil {
            Section("Connect an account") {
                HStack {
                    Button("ClientCore") { connection.origin = "https://meets.clientcore.ru" }
                    Button("Retail Rocket") { connection.origin = "https://boosty.retailrocket.ru" }
                }
                .disabled(connection.isConnecting)
                TextField("Installation address", text: $connection.origin)
                    .disabled(connection.isConnecting)
                Button("Connect and switch in browser") { connection.connect() }
                    .disabled(connection.isConnecting)
                Text(
                    """
                    Switching during a recording sends the entire current meeting to the selected account.
                    Earlier completed meetings keep their original destination.
                    """,
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var uploadsSection: some View {
        Section("Uploads") {
            if let error = uploads.storageError { Text(error).foregroundStyle(.red) }
            if uploads.entries.isEmpty { Text("No recordings queued for Boosty.").foregroundStyle(.secondary) }
            ForEach(Array(uploads.entries.suffix(8).reversed())) { entry in
                BoostyUploadEntryView(entry: entry, uploads: uploads)
            }
        }
    }

    private var explanationSection: some View {
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
}

private struct BoostyUploadEntryView: View {
    let entry: BoostyUploadEntry
    let uploads: BoostyUploadQueue
    @State private var selected = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.title).font(.headline)
            Text("Destination: " + (BoostyConnectionState.shared.accounts.first { $0.id == entry.accountKey }?.company ?? entry.origin))
                .font(.caption).foregroundStyle(.secondary)
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
        .onChange(of: entry.route) { _, _ in selected = "" }
    }
}
