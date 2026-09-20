import AppKit
import BytemeterCore

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var db: Database!
    private var settings: Settings!
    private var sampler: Sampler!
    private var statusController: StatusItemController!
    private var preferences: PreferencesWindow?
    private var maintenanceTimer: Timer?

    private let dbQueue = DispatchQueue(label: "io.github.adi-debug-source.bytemeter.db", qos: .utility)

    static var supportFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bytemeter", isDirectory: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let folder = Self.supportFolder

        // A second copy would double every figure. Step aside quietly.
        guard SingleInstance.claim(at: folder.appendingPathComponent("bytemeter.lock")) else {
            FileHandle.standardError.write(Data("Bytemeter: another copy is already running, quitting.\n".utf8))
            NSApp.terminate(nil)
            return
        }

        let path = folder.appendingPathComponent("bytemeter.db").path

        do {
            db = try Database(path: path)
        } catch {
            FileHandle.standardError.write(Data("Bytemeter: \(error)\n".utf8))
            let alert = NSAlert()
            alert.messageText = "Bytemeter could not open its database"
            alert.informativeText = "\(error)\n\nThe file is at \(path)."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let queue = dbQueue
        let database = db!
        settings = Settings(db: database, write: { work in queue.async { work() } })

        sampler = Sampler(db: db, settings: settings, queue: dbQueue)
        statusController = StatusItemController(settings: settings) { [weak self] body in
            guard let self else { return }
            let cal = BytemeterCalendar(cycleStartDay: self.settings.cycleStartDay)
            self.dbQueue.sync { body(Aggregator(db: self.db, cal: cal)) }
        }

        statusController.onOpenDashboard = { [weak self] in self?.openDashboard() }
        statusController.onOpenPreferences = { [weak self] in self?.openPreferences() }
        statusController.onLiveSpeedChanged = { [weak self] in self?.sampler.updateRateTimer() }

        sampler.onSample = { [weak self] in self?.statusController.refresh() }
        sampler.onRate = { [weak self] down, up in
            self?.statusController.updateRate(inBytes: down, outBytes: up)
        }

        registerSleepAndWake()
        sampler.start()

        // The daily tidy up. Nothing is scheduled outside the app: this timer
        // only exists while Bytemeter is running.
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.sampler.runMaintenanceCheck()
        }

        showFirstRunHintIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // One last reading, so the counters are saved right up to the moment of
        // quitting and the next launch has an accurate baseline.
        sampler?.sampleNow()
        dbQueue.sync { }
    }

    // MARK: - Sleep and wake

    /// Registering for the real notifications rather than guessing from a clock
    /// jump: on wake the counter delta covers the whole sleep, and it needs to
    /// be spread over those minutes rather than dumped into one.
    private func registerSleepAndWake() {
        let centre = NSWorkspace.shared.notificationCenter
        centre.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sampler.noteSleep()
        }
        centre.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sampler.noteWake()
        }
    }

    // MARK: - Actions

    private func openDashboard() {
        let folder = Self.supportFolder
        let cal = BytemeterCalendar(cycleStartDay: settings.cycleStartDay)
        dbQueue.async { [weak self] in
            guard let self else { return }
            let aggregator = Aggregator(db: self.db, cal: cal)
            let data = DashboardData(aggregator: aggregator, settings: self.settings, now: Date())
            do {
                let url = try DashboardGenerator.write(data: data, folder: folder)
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            } catch {
                FileHandle.standardError.write(Data("Bytemeter: dashboard failed: \(error)\n".utf8))
            }
        }
    }

    private func openPreferences() {
        if preferences == nil {
            preferences = PreferencesWindow(settings: settings) { [weak self] in
                self?.sampler.updateRateTimer()
                self?.statusController.refresh()
            }
        }
        preferences?.show()
    }

    /// Clicking cycles the total and right-clicking opens the menu, which is
    /// worth showing once rather than leaving him to find it.
    private func showFirstRunHintIfNeeded() {
        let database = db!
        dbQueue.async { [weak self] in
            guard database.state(StateKey.seenMenuHint) == nil else { return }
            database.setState(StateKey.seenMenuHint, "1")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self?.statusController.showMenu()
            }
        }
    }
}
