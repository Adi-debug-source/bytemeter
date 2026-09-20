import AppKit
import BytemeterCore

/// A small preferences window. Plain controls, no tabs, nothing hidden.
final class PreferencesWindow: NSWindowController {

    private let settings: Settings
    private let onChange: () -> Void

    private var liveSpeedBox: NSButton!
    private var ssidBox: NSButton!
    private var perAppBox: NSButton!
    private var capBox: NSButton!
    private var capField: NSTextField!
    private var cycleField: NSTextField!

    init(settings: Settings, onChange: @escaping () -> Void) {
        self.settings = settings
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
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildContent() {
        let stack = NSStackView()
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
        stack.addArrangedSubview(caption("Keeps a home connection separate from a hotspot or a cafe. Reading a network name needs Location Services on this version of macOS, so macOS will ask. While this is off, Bytemeter never touches Location Services."))

        stack.addArrangedSubview(divider())

        capBox = checkbox("Warn me against a monthly cap", settings.capEnabled, #selector(toggleCap))
        stack.addArrangedSubview(capBox)

        capField = NSTextField(string: settings.capBytes > 0 ? String(settings.capBytes / 1_000_000_000) : "")
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
        stack.addArrangedSubview(caption("1 means calendar months, which is what you are on. Change it only if your provider bills from a different day."))

        guard let content = window?.contentView else { return }
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
        ])
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
        settings.ssidCapture = ssidBox.state == .on
        onChange()
    }

    @objc private func toggleCap() {
        settings.capEnabled = capBox.state == .on
        onChange()
    }

    @objc private func capValueChanged() {
        let gigabytes = Int64(capField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
        settings.capBytes = max(0, gigabytes) * 1_000_000_000
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
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
