import MacSizeCore
import SwiftUI

/// Welcome-screen card showing whether the `macsize` command is installed,
/// with one-click install / update / repair / remove.
struct CommandLineToolCard: View {
    @State private var model = CommandLineToolModel()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "terminal")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Command-Line Tool").font(.headline)
                    statusBadge
                }
                details
                if let error = model.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)
            actions
        }
        .padding(14)
        .frame(width: 480)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .task { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Pick up installs/removals done from Terminal while the app was in the background.
            if !model.isWorking { model.refresh() }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch model.status {
        case .checking:
            ProgressView().controlSize(.mini)
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.green)
        case .needsAttention:
            Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.orange)
        case .notInstalled:
            Label("Not installed", systemImage: "xmark.circle")
                .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var details: some View {
        switch model.status {
        case .checking:
            Text("Checking for `\(MacSizeInfo.commandName)`…").font(.callout).foregroundStyle(.secondary)
        case .notInstalled:
            Text("Install `\(MacSizeInfo.commandName)` to scan from Terminal, e.g. `\(MacSizeInfo.commandName) ~ -d 1`.")
                .font(.callout).foregroundStyle(.secondary)
            if !model.canInstall {
                Text("This build doesn't include the tool. Build the app with scripts/build-app.sh.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case let .installed(install):
            Text(install.path)
                .font(.callout.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Text("Version \(install.version ?? "?")" + (install.isSymlink ? " · updates with the app" : ""))
                .font(.caption).foregroundStyle(.secondary)
        case let .needsAttention(install, reason):
            Text(install.path)
                .font(.callout.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Text(reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !install.isOnPath {
                Button("Copy PATH line for your shell config") { model.copyPathExport(install.directory) }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if model.isWorking {
            ProgressView().controlSize(.small)
        } else {
            switch model.status {
            case .checking:
                EmptyView()
            case .notInstalled:
                installMenu(title: "Install")
            case let .installed(install):
                Button("Uninstall") { model.uninstall(install) }
                    .help("Remove \(install.path)")
            case let .needsAttention(install, _):
                VStack(alignment: .trailing, spacing: 6) {
                    if install.isOnPath {
                        Button(install.isBroken ? "Repair" : "Update") { model.reinstall(install) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canInstall)
                            .help("Point \(install.path) at the tool inside this app")
                    } else {
                        installMenu(title: "Install on PATH")
                    }
                    Button("Uninstall") { model.uninstall(install) }
                        .buttonStyle(.link).font(.caption)
                }
            }
        }
    }

    private func installMenu(title: String) -> some View {
        Menu(title) {
            Button("For All Users (\(CommandLineToolManager.systemDirectory))…") { model.installSystemWide() }
            Button("Just for Me (~/.local/bin)") { model.installForCurrentUser() }
        } primaryAction: {
            model.installSystemWide()
        }
        .menuStyle(.button)
        .buttonStyle(.borderedProminent)
        .fixedSize()
        .disabled(!model.canInstall)
        .help("Installs a link to the tool inside MacSize.app, so it updates when the app does. "
            + "Installing for all users may ask for your password.")
    }
}
