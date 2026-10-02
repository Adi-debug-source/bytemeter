import AppKit
import BytemeterCore

/// A small preferences window. Plain controls, no tabs, nothing hidden.
final class PreferencesWindow: NSWindowController {

    private let settings: Settings
    private let networkNames: NetworkNameAccess
    private let onChange: () -> Void

    private var liveSpeedBox: NSButton!
    private var ssidBox: NSButton!
    private var ssidNote: NSTextField!
    private var ssidAction: NSButton!
    private var perAppBox: NSButton!
    private var capBox: NSButton!
    private var capField: NSTextField!
    private var cycleField: NSTextField!
    private var stack: NSStackView!

    init(settings: Settings, networkNames: NetworkNameAccess, onChange: @escaping () -> Void) {
        self.settings = settings
        self.networkNames = networkNames
        self.onChange = onChange

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 396),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Bytemeter Preferences"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildContent()
        networkNames.onUpdate = { [weak self] in self?.refreshNetworkName() }
        refreshNetworkName()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildContent() {
        stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        liveSpeedBox = checkbox("Show live speed in the menu bar", settings.liveSpeed, #selector(toggleLiveSpeed))
        stack.addArrangedSubview(liveSpeedBox)
        stack.addArrangedSubview(caption("Sits alongside the total rather than replacing it. Can be flipped from the menu too."))

        perAppBox = checkbox("Sample per-app usage with nettop", settings.perAppSampling, #selector(togglePerApp))
        stack.addArrangedSubview(perAppBox)
        stack.addArrangedSubview(caption("A good guide, not an exact split. A process that quits between samples takes its last few seconds with it."))

        ssidBox = checkbox("Record the Wi-Fi network name", settings.ssidCapture, #selector(toggleSSID))
        stack.addArrangedSubview(ssidBox)
        stack.addArrangedSubview(caption(NetworkNames.preferencesCaption))
        // Where things stand with Location Services, in full contrast because
        // it is news rather than description, and a button when one helps.
        ssidNote = caption("")
        ssidNote.textColor = .labelColor
        stack.addArrangedSubview(ssidNote)
        ssidAction = NSButton(title: "", target: self, action: #selector(networkNameAction))
        ssidAction.bezelStyle = .rounded
        ssidAction.controlSize = .small
        ssidAction.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        stack.addArrangedSubview(ssidAction)

        stack.addArrangedSubview(divider())

        capBox = checkbox("Warn me against a monthly cap", settings.capEnabled, #selector(toggleCap))
        stack.addArrangedSubview(capBox)

        capField = NSTextField(string: CapInput.text(forBytes: settings.capBytes))
        capField.placeholderString = "GB, for example 100"
        capField.target = self
        capField.action = #selector(capValueChanged)
        capField.translatesAutoresizingMaskIntoConstraints = false
        capField.widthAnchor.constraint(equalToConstant: 140).isActive = true
        stack.addArrangedSubview(labelled("Cap", capField))

        cycleField = NSTextField(string: String(settings.cycleStartDay))
        cycleField.target = self
        cycleField.action = #selector(cycleValueChanged)
        cycleField.translatesAutoresizingMaskIntoConstraints = false
        cycleField.widthAnchor.constraint(equalToConstant: 140).isActive = true
        stack.addArrangedSubview(labelled("Cycle starts on day", cycleField))
        stack.addArrangedSubview(caption("1 means calendar months, the usual case. Change it only if your provider bills from a different day of the month."))

        guard let content = window?.contentView else { return }
        content.addSubview(stack)
        // Pinned on all four sides; `fitWindow` then sizes the window to it.
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    /// The box, the note and the button, from where things stand now. Called
    /// when the window is built, when it is shown, and whenever macOS answers.
    func refreshNetworkName() {
        let status = networkNames.status
        ssidBox.state = settings.ssidCapture ? .on : .off
        let note = NetworkNames.preferencesNote(status)
        ssidNote.stringValue = note ?? ""
        ssidNote.isHidden = note == nil
        switch NetworkNames.action(status) {
        case .ask?:
            ssidAction.title = "Ask macOS"
            ssidAction.isHidden = false
        case .openSettings?:
            ssidAction.title = "Open Location Services settings"
            ssidAction.isHidden = false
        case nil:
            ssidAction.isHidden = true
        }
        fitWindow()
    }

    /// Gives the window exactly the height its controls need, so it grows for
    /// a long note and shrinks again when the note goes, rather than clipping
    /// one or leaving a gap. The title bar stays where it is.
    private func fitWindow() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let height = ceil(stack.fittingSize.height)
        guard abs(content.frame.height - height) > 0.5 else { return }
        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: content.frame.width, height: height))
        frame.origin.x = window.frame.minX
        frame.origin.y = window.frame.maxY - frame.height
        window.setFrame(frame, display: window.isVisible)
    }

    // MARK: - Controls

    private func checkbox(_ title: String, _ on: Bool, _ action: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.state = on ? .on : .off
        return button
    }

    private func caption(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 400).isActive = true
        return field
    }

    private func divider() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 400).isActive = true
        return line
    }

    private func labelled(_ title: String, _ field: NSTextField) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.spacing = 10
        return row
    }

    // MARK: - Actions

    @objc private func toggleLiveSpeed() {
        settings.liveSpeed = liveSpeedBox.state == .on
        onChange()
    }

    @objc private func togglePerApp() {
        settings.perAppSampling = perAppBox.state == .on
        onChange()
    }

    @objc private func toggleSSID() {
        if ssidBox.state == .on {
            networkNames.switchOn()
        } else {
            networkNames.switchOff()
        }
        refreshNetworkName()
        onChange()
    }

    @objc private func networkNameAction() {
        switch NetworkNames.action(networkNames.status) {
        case .ask?:
            networkNames.askAgain()
        case .openSettings?:
            // Opens the Location Services page of System Settings, where only
            // the user can change anything.
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                NSWorkspace.shared.open(url)
            }
        case nil:
            break
        }
        refreshNetworkName()
    }

    @objc private func toggleCap() {
        settings.capEnabled = capBox.state == .on
        onChange()
    }

    /// Clamped in the engine to a range that cannot overflow, so no typed
    /// number can crash the app, and the field shows what was kept.
    @objc private func capValueChanged() {
        settings.capBytes = CapInput.bytes(fromText: capField.stringValue)
        capField.stringValue = CapInput.text(forBytes: settings.capBytes)
        onChange()
    }

    @objc private func cycleValueChanged() {
        let day = Int(cycleField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 1
        let clamped = min(max(day, 1), 28)
        settings.cycleStartDay = clamped
        cycleField.stringValue = String(clamped)
        onChange()
    }

    func show() {
        refreshNetworkName()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
