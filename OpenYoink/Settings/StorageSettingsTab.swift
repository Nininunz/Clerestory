import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Storage and recovery

struct StorageSettingsTab: View {
    @Environment(StorageManagementController.self) private var storage
    @State private var snapshotToRestore: PersistenceController.RecoverySnapshot?
    @State private var pendingImportToDiscard: PendingImportJournal.Record?
    @State private var confirmsDiscard = false

    var body: some View {
        SettingsForm {
            Section("Managed Storage") {
                LabeledContent("Materialized files") {
                    Text(ByteCountFormatter.string(
                        fromByteCount: storage.materializedBytes,
                        countStyle: .file
                    ))
                    .monospacedDigit()
                }

                HStack {
                    Button("Clean Up Unused Files") { storage.cleanUnusedFiles() }
                        .disabled(!storage.canCleanUnusedFiles)
                    Button("Show Data Folder") { storage.revealDataFolder() }
                }

                if !storage.canCleanUnusedFiles {
                    Text("Cleanup is disabled while recovery data needs attention.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Pending Imports") {
                if storage.isPendingImportRecoveryDamaged {
                    Label("Pending import recovery data needs manual attention. Automatic cleanup is disabled.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else if storage.pendingImports.isEmpty {
                    Text("No received files are waiting to be imported.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(storage.pendingImports) { pending in
                        HStack(spacing: 10) {
                            Image(systemName: "tray.and.arrow.down.fill")
                                .foregroundStyle(.orange)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pending.displayName)
                                    .lineLimit(2)
                                Text(pending.createdAt, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Button("Retry Import") {
                                storage.retryPendingImport(pending)
                            }
                            .accessibilityIdentifier("storage.pendingImport.retry")

                            Button(role: .destructive) {
                                pendingImportToDiscard = pending
                            } label: {
                                Image(systemName: "trash")
                            }
                            .accessibilityLabel("Delete Pending Import")
                            .accessibilityIdentifier("storage.pendingImport.delete")
                        }
                    }

                    Text("These files are retained in OpenYoink's managed storage until you retry or delete them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Recovery") {
                if storage.snapshots.isEmpty {
                    Text("No recovery data is available.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(storage.snapshots) { snapshot in
                        HStack(spacing: 10) {
                            Image(systemName: snapshot.isRecoverable
                                  ? "clock.arrow.circlepath"
                                  : "exclamationmark.triangle")
                                .foregroundStyle(snapshot.isRecoverable ? Color.secondary : Color.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(storage.snapshotTitle(snapshot))
                                HStack(spacing: 6) {
                                    if let date = snapshot.modifiedAt {
                                        Text(date, style: .date)
                                        Text(date, style: .time)
                                    }
                                    Text(ByteCountFormatter.string(
                                        fromByteCount: snapshot.byteCount,
                                        countStyle: .file
                                    ))
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if snapshot.isRecoverable {
                                Button("Restore…") { snapshotToRestore = snapshot }
                            } else {
                                Text("Manual repair required")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Button("Delete All Recovery Data…", role: .destructive) {
                        confirmsDiscard = true
                    }
                }

                if let message = storage.statusMessage {
                    Label(message, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if let error = storage.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .onAppear { storage.refresh() }
        .alert("Restore Shelf Data?", isPresented: Binding(
            get: { snapshotToRestore != nil },
            set: { if !$0 { snapshotToRestore = nil } }
        )) {
            Button("Cancel", role: .cancel) { snapshotToRestore = nil }
            Button("Restore") {
                if let snapshot = snapshotToRestore { storage.restore(snapshot) }
                snapshotToRestore = nil
            }
        } message: {
            Text("The current shelf will be preserved as a backup before the selected snapshot is restored.")
        }
        .alert("Delete All Recovery Data?", isPresented: $confirmsDiscard) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { storage.discardAllRecoveryData() }
        } message: {
            Text("This removes OpenYoink's recovery snapshots. Files currently on the shelf are not deleted.")
        }
        .alert("Delete Pending Import?", isPresented: Binding(
            get: { pendingImportToDiscard != nil },
            set: { if !$0 { pendingImportToDiscard = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingImportToDiscard = nil }
            Button("Delete", role: .destructive) {
                if let pending = pendingImportToDiscard {
                    storage.discardPendingImport(pending)
                }
                pendingImportToDiscard = nil
            }
        } message: {
            Text("This permanently deletes OpenYoink's retained copy. The source application may no longer be able to provide it again.")
        }
    }
}

