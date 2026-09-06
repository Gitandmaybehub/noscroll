import SwiftUI

/// Every service's switches in one place, rather than one sheet at a time.
struct AllSettingsTab: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationStack {
            List {
                ForEach(AppState.services) { service in
                    Section {
                        ForEach(state.surfaces(for: service.id)) { group in
                            Toggle(group.label,
                                   isOn: state.binding(service: service.id, surfaces: group.keys))
                        }
                    } header: {
                        HStack(spacing: 8) {
                            BrandMark(service: service.id, size: 15)
                                .padding(5)
                                .background(service.gradient, in: RoundedRectangle(cornerRadius: 6))
                            Text(service.name)
                            if service.beta {
                                Text("BETA").font(.caption2.bold())
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.2), in: Capsule())
                            }
                        }
                    }
                }
            }
            .navigationTitle("What's blocked")
        }
    }
}

struct ProfileTab: View {
    @EnvironmentObject private var state: AppState
    var body: some View {
        NavigationStack {
            List {
                Section("NoScroll CG") {
                    Text("Christian's personal edition of NoScroll.")
                    Text("Blocks Reels, Shorts and selected feeds inside this browser. It does not lock other apps or measure Screen Time.")
                        .foregroundStyle(.secondary)
                }
                Section("Privacy") {
                    Text("Website sessions are stored on this iPhone. There is no account for this app and no analytics service.")
                    Text("Sign in on each service's own page. Blocking pauses on sign-in pages.")
                        .foregroundStyle(.secondary)
                }
                Section("Rules") {
                    ForEach(AppState.services) { service in
                        LabeledContent(service.name, value: state.bundleVersion(for: service.id))
                    }
                }
                Section("Source") {
                    Link("My fork", destination: URL(string: "https://github.com/Gitandmaybehub/noscroll")!)
                    Link("Original NoScroll", destination: URL(string: "https://github.com/Blueturboguy07/noscroll")!)
                    Text("AGPL-3.0-or-later. Original work by Blueturboguy07 and contributors. No affiliation with the services opened here.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("About")
        }
    }
}
