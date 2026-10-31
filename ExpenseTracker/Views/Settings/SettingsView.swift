import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext

    private struct PendingRestore {
        let data: Data
        let summary: BackupSummary
    }

    private struct Message: Identifiable {
        let id = UUID()
        let title: String
        let text: String
    }

    @State private var exportDocument = BackupDocument(data: Data())
    @State private var exportName = "ExpenseTracker-Backup"
    @State private var isExporting = false
    @State private var exportIsBeforeRestore = false
    @State private var backedUpFirst = false
    @State private var isImporting = false
    @State private var pending: PendingRestore?
    @State private var showRestoreAlert = false
    @State private var message: Message?

    private static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    private static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        Form {
            Section {
                Button { startExport(beforeRestore: false) } label: {
                    Label("Back up data", systemImage: "square.and.arrow.up")
                }
                Button { isImporting = true } label: {
                    Label("Restore from backup", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("Backup")
            } footer: {
                Text("Saves your wallets, categories and transactions to a file you choose. Restoring replaces all current data, so back up first. Keep backups somewhere safe: deleting the app deletes its data.")
            }
            .listRowBackground(AppTheme.surface)

            Section("About") {
                LabeledContent("Version", value: Self.version)
            }
            .listRowBackground(AppTheme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportName
        ) { outcome in
            if !exportIsBeforeRestore {
                switch outcome {
                case .success:
                    message = Message(title: "Backup saved",
                                      text: "Keep the file somewhere safe, such as iCloud Drive.")
                case .failure(let error):
                    if (error as? CocoaError)?.code != .userCancelled {
                        message = Message(title: "Couldn't save the backup",
                                          text: "The file wasn't saved. Please try again.")
                    }
                }
            } else if case .success = outcome {
                backedUpFirst = true
            }
        }
        .onChange(of: isExporting) { _, nowExporting in
            // After a "back up first" export (saved or cancelled), return to the confirmation.
            if !nowExporting && exportIsBeforeRestore {
                exportIsBeforeRestore = false
                later { showRestoreAlert = true }
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { outcome in
            switch outcome {
            case .success(let url): load(url)
            case .failure:
                message = Message(title: "Can't open the file", text: "The file couldn't be opened.")
            }
        }
        .alert("Replace all data?", isPresented: $showRestoreAlert, presenting: pending) { _ in
            Button("Back up current data first") { later { startExport(beforeRestore: true) } }
            Button("Replace all data", role: .destructive) { restore() }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { item in
            Text("\(item.summary.text)\n\nRestoring replaces all current data on this device. This can't be undone."
                 + (backedUpFirst ? "\n\nYour current data was backed up." : ""))
        }
        .alert(message?.title ?? "", isPresented: messageIsPresented, presenting: message) { _ in
            Button("OK", role: .cancel) {}
        } message: { item in
            Text(item.text)
        }
    }

    // MARK: Actions

    /// Lets one sheet or alert finish dismissing before the next is shown.
    private func later(_ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            work()
        }
    }

    private func startExport(beforeRestore: Bool) {
        do {
            let data = try BackupService(context: modelContext).export(appVersion: Self.shortVersion)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            exportDocument = BackupDocument(data: data)
            exportName = "ExpenseTracker-Backup-\(formatter.string(from: Date()))"
            exportIsBeforeRestore = beforeRestore
            isExporting = true
        } catch {
            message = Message(title: "Backup failed",
                              text: "Your data couldn't be read for the backup. Nothing was changed.")
            if beforeRestore { showRestoreAlert = true }
        }
    }

    private func load(_ url: URL) {
        do {
            // Bounded read: never loads more than the limit, whatever the file claims.
            let data = try BackupService.readBounded(from: url)
            let checked = try BackupService.decodeAndValidate(data)
            pending = PendingRestore(data: data, summary: checked.summary)
            backedUpFirst = false
            later { showRestoreAlert = true }
        } catch let error as BackupError {
            message = Message(title: "Can't restore this file", text: error.message)
        } catch {
            message = Message(title: "Can't open the file", text: "The file couldn't be read.")
        }
    }

    private func restore() {
        guard let item = pending else { return }
        pending = nil
        do {
            try BackupService(context: modelContext).restore(data: item.data)
            message = Message(title: "Restore complete",
                              text: "Restored \(item.summary.text). Open Home to see your data.")
        } catch let error as BackupError {
            message = Message(title: "Restore failed",
                              text: "\(error.message) Your existing data was not changed.")
        } catch {
            message = Message(title: "Restore failed",
                              text: "The restore couldn't be completed. Your existing data was not changed.")
        }
    }

    private var messageIsPresented: Binding<Bool> {
        Binding(get: { message != nil }, set: { if !$0 { message = nil } })
    }
}

#Preview {
    NavigationStack { SettingsView() }
        .modelContainer(for: [Wallet.self, Category.self, Transaction.self], inMemory: true)
}
