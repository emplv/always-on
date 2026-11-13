import SwiftUI

@main
struct AlwaysOnApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var session = KeepAwake.shared
    @AppStorage(DefaultsKey.showCountdownInMenuBar) private var showCountdown = false

    var body: some Scene {
        MenuBarExtra {
            PanelView(session: session)
        } label: {
            if showCountdown, let countdown = session.menuBarCountdown {
                HStack {
                    Image(systemName: menuBarSymbol)
                    Text(countdown).monospacedDigit()
                }
            } else {
                Image(systemName: menuBarSymbol)
            }
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarSymbol: String {
        if session.uptimeStatus != .ok { return "exclamationmark.triangle.fill" }
        return session.isKeepingAwake ? "cup.and.saucer.fill" : "cup.and.saucer"
    }
}

enum DefaultsKey {
    static let showCountdownInMenuBar = "showCountdownInMenuBar"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        LoginItem.enableOnFirstLaunch()
        Uptime.requestNotificationPermission()
    }

    func applicationWillTerminate(_ notification: Notification) {
        KeepAwake.shared.prepareForQuit()
    }
}

struct PanelView: View {
    @ObservedObject var session: KeepAwake
    @State private var startsAtLogin = LoginItem.isEnabled
    @AppStorage(DefaultsKey.showCountdownInMenuBar) private var showCountdown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SwitchRow(
                title: "Keep always on",
                isOn: Binding(get: { session.isOn }, set: session.setOn),
                caption: session.statusText,
                titleFont: .headline
            )

            if let countdown = session.countdownText {
                HStack {
                    Text(countdown)
                        .font(.system(.title2, design: .rounded).monospacedDigit())
                    Spacer()
                    Toggle("Show in menu bar", isOn: $showCountdown)
                        .toggleStyle(.checkbox)
                }
            }

            Picker("Duration", selection: Binding(get: { session.length }, set: session.setLength)) {
                Text(SessionLength.indefinitely.title).tag(SessionLength.indefinitely)
                Divider()
                ForEach(SessionLength.hours) { Text($0.title).tag($0) }
                Divider()
                ForEach(SessionLength.days) { Text($0.title).tag($0) }
                Divider()
                Text(SessionLength.untilDate.title).tag(SessionLength.untilDate)
            }

            if session.length == .untilDate {
                DatePicker(
                    "Until",
                    selection: Binding(get: { session.untilDate }, set: session.setUntilDate),
                    in: Date()...,
                    displayedComponents: [.date, .hourAndMinute]
                )
            }

            Divider()

            SwitchRow(
                title: "Keep awake while agents work",
                isOn: Binding(get: { session.keepAwakeForAgents }, set: session.setKeepAwakeForAgents),
                caption: session.agentCaption
            )

            if LidSleep.hasLid {
                Divider()

                // One setting for both modes; it does nothing while both are off.
                SwitchRow(
                    title: "Keep awake with lid closed",
                    isOn: Binding(get: { session.lidClosed }, set: session.setLidClosed),
                    caption: session.lidCaption,
                    captionColor: session.lidError == nil ? .secondary : .red
                )
                .disabled(!session.isModeOn)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Uptime")
                    Spacer()
                    Text(session.uptimeText)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if let warning = session.uptimeWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(session.uptimeStatus == .restartNow ? Color.red : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            SwitchRow(
                title: "Start at login",
                isOn: Binding(get: { startsAtLogin }, set: { enabled in
                    LoginItem.set(enabled)
                    startsAtLogin = LoginItem.isEnabled
                }),
                caption: LoginItem.needsApproval ? "Allow it in System Settings → General → Login Items." : nil
            )

            Button("Quit Always On") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { startsAtLogin = LoginItem.isEnabled }
    }
}

private struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool
    var caption: String?
    var captionColor: Color = .secondary
    var titleFont: Font = .body

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: $isOn) {
                Text(title)
                    .font(titleFont)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)

            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(captionColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
