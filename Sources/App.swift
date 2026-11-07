import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

@main
struct Main {
    static func main() {
        // CLI mode for scripting/testing: `Drive\ in\ Finder <link> [--reveal]`
        let args = Array(CommandLine.arguments.dropFirst())
        if let link = args.first(where: { !$0.hasPrefix("-") }) {
            do {
                let r = try DriveResolver.resolve(link)
                print(r.url.path)
                if args.contains("--reveal") { NSWorkspace.shared.activateFileViewerSelecting([r.url]) }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data(((error as? LocalizedError)?.errorDescription ?? "\(error)").utf8 + [10]))
                if case DriveResolver.Failure.notOnDisk(_, let tried) = error {
                    tried.forEach { FileHandle.standardError.write(Data("  tried: \($0)\n".utf8)) }
                }
                exit(1)
            }
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppModel: ObservableObject {
    @Published var input = ""
    @Published var message: String?
    @Published var isError = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    var onDone: (() -> Void)?

    func prefillFromClipboard() {
        if let s = NSPasteboard.general.string(forType: .string), DriveResolver.looksLikeDriveLink(s) {
            input = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        message = nil
    }

    /// Returns true if the item was revealed.
    @discardableResult
    func reveal(_ text: String? = nil) -> Bool {
        let link = text ?? input
        do {
            let r = try DriveResolver.resolve(link)
            NSWorkspace.shared.activateFileViewerSelecting([r.url])
            message = r.url.lastPathComponent
            isError = false
            onDone?()
            return true
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            isError = true
            return false
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            message = "Couldn't change login item: \(error.localizedDescription)"
            isError = true
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

struct PopoverView: View {
    @ObservedObject var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reveal Drive link in Finder").font(.headline)
            HStack {
                TextField("Paste a drive.google.com link", text: $model.input)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { model.reveal() }
                Button("Reveal") { model.reveal() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.input.isEmpty)
            }
            if let msg = model.message {
                Label(msg, systemImage: model.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(model.isError ? .orange : .green)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Text("⌃⌥⌘D reveals the link on your clipboard")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    .toggleStyle(.checkbox).font(.caption)
                Button("Quit") { NSApp.terminate(nil) }.font(.caption)
            }
        }
        .padding(14)
        .frame(width: 440)
        .onAppear { focused = true }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let model = AppModel()
    private var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: "Drive in Finder")
            button.action = #selector(togglePopover)
            button.target = self
        }
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PopoverView(model: model))
        model.onDone = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.popover.performClose(nil) }
        }
        registerHotKey()
    }

    @objc func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        model.prefillFromClipboard()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Hotkey: reveal whatever Drive link is on the clipboard; open the popover if it fails.
    fileprivate func hotKeyPressed() {
        let clip = NSPasteboard.general.string(forType: .string) ?? ""
        model.input = clip.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.reveal(clip) {
            showPopover()
            if clip.isEmpty || DriveResolver.extractID(from: clip) == nil {
                model.message = "No Google Drive link on the clipboard."
                model.isError = true
            }
        }
    }

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { delegate.hotKeyPressed() }
            return noErr
        }, 1, &spec, selfPtr, nil)

        let id = EventHotKeyID(signature: OSType(0x44524946), id: 1) // 'DRIF'
        RegisterEventHotKey(UInt32(kVK_ANSI_D), UInt32(cmdKey | optionKey | controlKey), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}
