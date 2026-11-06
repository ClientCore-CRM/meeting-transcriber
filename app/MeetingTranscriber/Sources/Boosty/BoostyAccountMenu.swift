import SwiftUI

/// Shared observation keeps the status-bar badge and the first menu rows in sync.
struct BoostyAccountBadge: View {
    private var connection: BoostyConnectionState {
        .shared
    }

    var body: some View {
        if connection.accounts.count > 1, let account = connection.activeAccount {
            Text(account.badge)
                .font(.system(size: 10, weight: .semibold))
                .accessibilityLabel("Boosty account: \(account.company), \(account.email)")
        }
    }
}

struct BoostyAccountMenu: View {
    var onManageAccounts: () -> Void
    private var connection: BoostyConnectionState {
        .shared
    }

    var body: some View {
        if !connection.accounts.isEmpty {
            Text("Boosty account").font(.caption).foregroundStyle(.secondary)
            ForEach(connection.accounts) { account in
                Button {
                    connection.selectAccount(account.id)
                } label: {
                    Label(
                        "\(account.company) — \(account.email)",
                        systemImage: account.id == connection.credential?.accountKey ? "checkmark" : "person.crop.circle",
                    )
                }
                .disabled(connection.isConnecting)
            }
            if BoostyUploadQueue.current?.entries.contains(where: { $0.captureStoppedAt == nil }) == true {
                Text("Current meeting goes to the selected account from the beginning.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if connection.status.hasPrefix("Could not") || connection.status.hasPrefix("Connection expired") {
                Text(connection.status).font(.caption).foregroundStyle(.red)
            }
            Button("Manage Boosty accounts…") {
                connection.settingsRequested = true
                onManageAccounts()
            }
            Divider()
        }
    }
}
