import SwiftUI
import SwiftData

struct LLMProviderSettingsView: View {
    @Query private var messages: [ChatMessage]
    @Query private var sessions: [LoggingSession]
    @Query private var traces: [AgentTraceRecord]
    @Query private var evidence: [ResolvedFoodEvidence]
    @Environment(\.modelContext) private var modelContext

    @State private var showLocalDeleteConfirm = false
    @State private var showCloudDeleteConfirm = false
    @State private var isDeletingCloudData = false
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "cloud.fill")
                        .font(.title3)
                        .foregroundStyle(NomvaTheme.accent)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nomva Cloud")
                            .font(.subheadline.weight(.medium))
                        Text("Task-specific GPT-5 models")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(NomvaTheme.accent)
                        .font(.title3)
                }
                .padding(.vertical, 4)
            } header: {
                Text("AI Provider")
            } footer: {
                Text("AI features need an internet connection. Manual search and logging remain available offline.")
            }

            Section("What Is Sent") {
                Label("Your current request", systemImage: "text.bubble")
                Label("Up to 6 recent chat messages for references like “that”", systemImage: "arrow.uturn.backward")
                Label("Relevant recent food, water, weight, and goal summaries for questions", systemImage: "list.bullet.clipboard")
                Label("A photo only when you choose Photo Scan", systemImage: "photo")
            }

            Section {
                Text("Nomva stores hashed operational metadata such as route, timing, status, model, and token counts for up to 90 days. Nomva analytics do not store raw chat text, food names, photos, or barcodes.")
                    .font(.subheadline)

                Text("Your food log, chat history, custom foods, templates, goals, hydration, and weight history remain in your selected on-device or private iCloud data store.")
                    .font(.subheadline)
            } header: {
                Text("Storage And Retention")
            }

            Section {
                Button(role: .destructive) {
                    showLocalDeleteConfirm = true
                } label: {
                    Label("Delete On-Device AI History", systemImage: "trash")
                }

                Button(role: .destructive) {
                    showCloudDeleteConfirm = true
                } label: {
                    HStack {
                        Label("Delete Cloud Analytics", systemImage: "cloud")
                        Spacer()
                        if isDeletingCloudData {
                            ProgressView()
                        }
                    }
                }
                .disabled(isDeletingCloudData)

                if let statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Delete AI Data")
            } footer: {
                Text("Deleting AI history does not delete nutrition, hydration, goal, or weight records.")
            }
        }
        .navigationTitle("AI & Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Delete on-device AI history?", isPresented: $showLocalDeleteConfirm) {
            Button("Delete", role: .destructive) {
                deleteLocalAIHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes chat messages, pending AI sessions, diagnostic traces, and match evidence. Logged health data stays intact.")
        }
        .alert("Delete cloud analytics?", isPresented: $showCloudDeleteConfirm) {
            Button("Delete", role: .destructive) {
                Task { await deleteCloudAnalytics() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes operational analytics linked to this Nomva identity.")
        }
    }

    private func deleteLocalAIHistory() {
        for item in messages { modelContext.delete(item) }
        for item in sessions { modelContext.delete(item) }
        for item in traces { modelContext.delete(item) }
        for item in evidence { modelContext.delete(item) }

        do {
            try modelContext.save()
            statusMessage = "On-device AI history deleted."
        } catch {
            modelContext.rollback()
            statusMessage = "Could not delete on-device AI history."
        }
    }

    @MainActor
    private func deleteCloudAnalytics() async {
        isDeletingCloudData = true
        defer { isDeletingCloudData = false }

        do {
            let deleted = try await RemoteAPIProvider().deleteCloudAnalytics()
            statusMessage = deleted == 1
                ? "Deleted 1 cloud analytics event."
                : "Deleted \(deleted) cloud analytics events."
        } catch {
            statusMessage = "Could not delete cloud analytics. Please try again."
        }
    }
}
