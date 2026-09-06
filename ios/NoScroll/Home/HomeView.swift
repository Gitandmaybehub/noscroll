import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var state: AppState
    @State private var openService: AppState.Service?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Christian's edition").font(.headline)
                        Text("Choose an app").font(.title2.bold())
                        Text("Reels and Shorts blocking starts when you open a service here. Change any rule in Blocks.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
                if let error = state.loadError {
                    Section {
                        Label("Blocking rules could not load", systemImage: "exclamationmark.triangle")
                        Text(error).font(.footnote)
                    }
                }
                Section("Your apps") {
                    ForEach(AppState.services.filter { !$0.beta }) { service in
                        serviceRow(service)
                    }
                }
                Section {
                    ForEach(AppState.services.filter { $0.beta }) { service in
                        serviceRow(service)
                    }
                } header: {
                    Text("Beta")
                } footer: {
                    Text("Beta rules may miss parts of these sites. Blocking applies inside NoScroll CG. Other apps and Safari stay separate.")
                }
            }
            .navigationTitle("NoScroll CG")
        }
        .fullScreenCover(item: $openService) { WebScreen(service: $0) }
        .onAppear { openPendingService() }
        .onChange(of: state.pendingService) { _, _ in openPendingService() }
    }

    private func serviceRow(_ service: AppState.Service) -> some View {
        Button { openService = service } label: {
            HStack(spacing: 14) {
                Image(systemName: service.symbol)
                    .font(.title3).foregroundStyle(service.tint)
                    .frame(width: 36, height: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(service.name).font(.headline).foregroundStyle(.primary)
                    Text(state.rawBundles[service.id] == nil ? "Rules unavailable" : blockingSummary(service))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
            }
            .padding(.vertical, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state.rawBundles[service.id] == nil || state.engineSource.isEmpty)
        .accessibilityLabel("Open \(service.name)")
    }

    private func blockingSummary(_ service: AppState.Service) -> String {
        let groups = state.surfaces(for: service.id)
        let enabled = groups.filter { state.binding(service: service.id, surfaces: $0.keys).wrappedValue }.count
        return "\(enabled) of \(groups.count) blocks on"
    }

    private func openPendingService() {
        guard let id = state.pendingService, let service = AppState.service(id) else { return }
        openService = service
        state.pendingService = nil
    }
}
