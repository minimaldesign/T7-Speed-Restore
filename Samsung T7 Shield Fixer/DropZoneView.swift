import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    let isTargeted: Binding<Bool>
    let onDrop: (URL) -> Void

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop your Samsung T7 here")
                .font(.headline)
            Text("APFS-formatted drives only. Back up exFAT drives and reformat to APFS first.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                )
                .foregroundStyle(hovering ? Color.accentColor : Color.secondary.opacity(0.5))
        )
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(hovering ? Color.accentColor.opacity(0.06) : Color.clear)
        )
        .onDrop(of: [.fileURL], isTargeted: Binding(
            get: { hovering },
            set: { newValue in
                hovering = newValue
                isTargeted.wrappedValue = newValue
            }
        )) { providers in
            handleDrop(providers: providers)
        }
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                onDrop(url)
            }
        }
        return true
    }
}
