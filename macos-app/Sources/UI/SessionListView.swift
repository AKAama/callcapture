import SwiftUI

/// Displays all sessions in a NavigationSplitView with list + detail layout.
///
/// Features:
/// - Searchable list filtered by title or date string
/// - Sorted by date descending (newest first)
/// - Empty state when no sessions exist
/// - Clicking a row navigates to session detail
@available(macOS 14.2, *)
struct SessionListView: View {
    @Environment(AppModel.self) private var appModel
    @State private var searchText = ""
    @State private var selectedSessionID: String?

    var body: some View {
        NavigationSplitView {
            Group {
                if filteredSessions.isEmpty {
                    emptyState
                } else {
                    sessionList
                }
            }
            .navigationTitle("Sessions")
            .searchable(text: $searchText, prompt: "Filter sessions")
        } detail: {
            if let id = selectedSessionID,
               let session = appModel.sessionManager.recentSessions.first(where: { $0.id == id }) {
                // Tie the detail view's identity to the session id so switching
                // sessions rebuilds it fresh. Without this, SwiftUI reuses the
                // same instance and its @State (liveSession, analysis, title) —
                // populated only in onAppear — stays stale on the prior session.
                SessionDetailView(session: session)
                    .id(session.id)
            } else {
                ContentUnavailableView(
                    "No Session Selected",
                    systemImage: "waveform",
                    description: Text("Select a session from the sidebar to view details.")
                )
            }
        }
        .frame(minWidth: 680, minHeight: 460)
    }

    @ViewBuilder
    private var sessionList: some View {
        List(filteredSessions, selection: $selectedSessionID) { session in
            SessionRowView(session: session)
                .tag(session.id)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        ContentUnavailableView(
            searchText.isEmpty ? "No Sessions" : "No Results",
            systemImage: searchText.isEmpty ? "waveform.slash" : "magnifyingglass",
            description: Text(
                searchText.isEmpty
                    ? "Record your first session from the menu bar."
                    : "No sessions match \"\(searchText)\"."
            )
        )
    }

    private var filteredSessions: [Session] {
        let sorted = appModel.sessionManager.recentSessions.sorted {
            $0.startedAt > $1.startedAt
        }
        guard !searchText.isEmpty else { return sorted }
        let query = searchText.lowercased()
        return sorted.filter { session in
            session.title.lowercased().contains(query)
                || formattedDate(session.startedAt).lowercased().contains(query)
        }
    }

    private func formattedDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
