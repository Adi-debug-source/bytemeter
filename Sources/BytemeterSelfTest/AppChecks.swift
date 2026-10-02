import Foundation
import BytemeterCore

// Checks for the rules the macOS app layer takes from the engine: the menu's
// peaks and projection, the CSV export's cells, the cap typed into
// Preferences, and when a Wi-Fi network name may be read. Each one was found
// wrong by a review on 2 October 2026, and each check below fails if its fix
// is undone.

func runAppChecks() {
    checkPeaksAreDownloadOnly()
    checkProjectionWording()
    checkCSVCells()
    checkCapInput()
    checkNetworkNameRules()
}

// MARK: - Peaks, by download, as the dashboard has them

private func checkPeaksAreDownloadOnly() {
    // As of 29 September at 21:30. The heaviest download day and hour are not
    // the heaviest combined ones, so a peak picked or printed by download plus
    // upload shows up as the wrong day, the wrong hour or the wrong figure.
    let now = london.parseLocal("2026-09-29T21:30")!
    let db = makeDatabase()
    func at(_ local: String, _ bytesIn: UInt64, _ bytesOut: UInt64) {
        let minute = BytemeterCalendar.minute(from: london.parseLocal(local)!)
        db.addBuckets([BucketDelta(minute: minute, iface: "en0", bytesIn: bytesIn, bytesOut: bytesOut)],
                      ssid: ssidPlaceholder, idle: false)
    }
    at("2026-09-26T12:00", 5_000_000_000, 100_000_000)     // most downloaded
    at("2026-09-27T12:00", 3_000_000_000, 4_000_000_000)   // most in total
    at("2026-09-29T10:15", 900_000_000, 50_000_000)        // most downloaded today
    at("2026-09-29T14:15", 200_000_000, 2_000_000_000)     // most in total today

    let aggregator = Aggregator(db: db, cal: london)
    check(aggregator.peakDayThisCycle(now: now)?.label != aggregator.peakDownloadDayThisCycle(now: now)?.label
          && aggregator.peakHourToday(now: now)?.hour != aggregator.peakDownloadHourToday(now: now)?.hour,
          "the peak data really does tell download apart from download plus upload")
    expect(aggregator.peakDownloadHourToday(now: now)?.hour, 10, "the dashboard's busiest hour is picked by download")
    expect(aggregator.peakDownloadDayThisCycle(now: now)?.label, "26 Sep", "the peak day is picked by download")

    let snapshot = MenuSnapshot(aggregator: aggregator, now: now)
    expect(snapshot.peakHourText, "Peak hour today: 10:00, ↓ " + Units.bytes(900_000_000),
           "the menu's peak hour is the download figure, marked ↓")
    expect(snapshot.peakDayText, "Peak day this month: 26 Sep, ↓ " + Units.bytes(5_000_000_000),
           "the menu's peak day is the download figure, marked ↓")
    let peakDay = aggregator.peakDownloadDayThisCycle(now: now)?.totals.bytesIn ?? .max
    check(peakDay <= snapshot.thisMonth.bytesIn, "the peak day can never read larger than this month above it")

    let empty = MenuSnapshot(aggregator: Aggregator(db: makeDatabase(), cal: london), now: now)
    expect(empty.peakHourText, "Peak hour today: nothing yet", "no traffic, no peak hour")
    expect(empty.peakDayText, "Peak day this month: nothing yet", "no traffic, no peak day")
    let cycle = BytemeterCalendar(timeZone: london.calendar.timeZone, cycleStartDay: 15)
    let cycleSnapshot = MenuSnapshot(aggregator: Aggregator(db: db, cal: cycle), now: now)
    expect(cycleSnapshot.peakDayText, "Peak day this cycle: 26 Sep, ↓ " + Units.bytes(5_000_000_000),
           "a billing cycle is called a cycle")
    let cycleLines = MenuModel.information(cycleSnapshot, options: MenuModel.Options(
        liveSpeed: false, rateIn: 0, rateOut: 0, capEnabled: false, capBytes: 0, perAppSampling: false))
    check(cycleLines.contains { if case .figure("Per day this cycle", _, _, false) = $0 { return true } else { return false } },
          "and so is its daily average")
}

// MARK: - The projection says what it adds up, and when the month ends

private func checkProjectionWording() {
    func wording(_ local: String, cycleStartDay: Int = 1) -> ProjectionWording {
        let cal = BytemeterCalendar(timeZone: london.calendar.timeZone, cycleStartDay: cycleStartDay)
        return ProjectionWording(projected: Totals(bytesIn: 60_000_000_000, bytesOut: 40_800_000_000),
                                 now: cal.parseLocal(local)!, cal: cal)
    }
    let late = wording("2026-09-29T21:30")
    expect(late.deadline, "by the end of September", "seen on 29 September, it is the end of September, not 1 Oct")
    expect(late.figure, Units.bytes(100_800_000_000), "the projection is download and upload together")
    expect(late.headline, "On track for \(Units.bytes(100_800_000_000)) by the end of September", "the menu's line")
    expect(wording("2026-10-01T00:00").deadline, "by the end of October", "the first minute of a month")
    expect(wording("2027-02-10T12:00").deadline, "by the end of February", "a short month")
    expect(wording("2026-12-31T23:59").deadline, "by the end of December", "the last minute of a year")
    expect(wording("2026-09-29T21:30", cycleStartDay: 15).deadline, "by the end of the cycle, 14 Oct",
           "a billing cycle names its own last day")
    expect(wording("2026-10-15T00:00", cycleStartDay: 15).deadline, "by the end of the cycle, 14 Nov",
           "and moves on when the next cycle starts")
    check(ProjectionWording.basis.contains("down and up"), "the basis says download and upload are added together")

    // The menu prints the same two parts the dashboard tile does, the basis
    // directly under the line it explains.
    let now = london.parseLocal("2026-09-29T21:30")!
    let db = makeDatabase()
    db.addBuckets([BucketDelta(minute: BytemeterCalendar.minute(from: london.parseLocal("2026-09-10T09:00")!),
                               iface: "en0", bytesIn: 40_000_000_000, bytesOut: 5_000_000_000)],
                  ssid: ssidPlaceholder, idle: false)
    let snapshot = MenuSnapshot(aggregator: Aggregator(db: db, cal: london), now: now)
    let lines = MenuModel.information(snapshot, options: MenuModel.Options(
        liveSpeed: false, rateIn: 0, rateOut: 0, capEnabled: false, capBytes: 0, perAppSampling: true))
    let expected = Aggregator(db: db, cal: london).projection(now: now).projected
    expect(snapshot.projection.figure, Units.bytes(expected.total), "the menu projects the combined total")
    if let index = lines.firstIndex(of: .text(snapshot.projection.headline)), index > 0, index + 1 < lines.count {
        expect(lines[index - 1], .header("Looking ahead"), "the projection opens Looking ahead")
        expect(lines[index + 1], .caption(ProjectionWording.basis), "with its basis right under it")
    } else {
        check(false, "the menu shows the projection's headline")
    }
}

// MARK: - CSV cells cannot run as formulas

/// A small RFC 4180 reader for one line, so the checks read cells back the
/// way a spreadsheet would rather than comparing strings by eye.
private func readCSVLine(_ line: String) -> [String] {
    var cells: [String] = [], cell = "", quoted = false
    var chars = Array(line.unicodeScalars)[...]
    while let c = chars.popFirst() {
        if quoted {
            if c == "\"" {
                if chars.first == "\"" { cell.unicodeScalars.append("\""); chars.removeFirst() } else { quoted = false }
            } else { cell.unicodeScalars.append(c) }
        } else if c == "\"" { quoted = true
        } else if c == "," { cells.append(cell); cell = ""
        } else { cell.unicodeScalars.append(c) }
    }
    cells.append(cell)
    return cells
}

private func checkCSVCells() {
    for start in ["=", "+", "-", "@", "\t", "\r"] {
        let hostile = start + "HYPERLINK(\"http://example.invalid\")"
        let read = readCSVLine("x," + CSVCell.text(hostile) + ",1")
        expect(read.count, 3, "a hostile cell starting \(start.debugDescription) stays one cell")
        expect(read.dropFirst().first, "'" + hostile, "a cell starting \(start.debugDescription) gets a leading apostrophe")
    }
    expect(CSVCell.text("=cmd|' /C calc'!A0"), "\"'=cmd|' /C calc'!A0\"", "the review's DDE payload is neutralised")
    expect(CSVCell.text("\r\n=1+1").unicodeScalars.dropFirst().first, "'",
           "a carriage return and line feed, one Character in Swift, is still caught")
    expect(CSVCell.text("Safari"), "\"Safari\"", "an ordinary name is only quoted")
    expect(CSVCell.text("Thursday 1 October 2026"), "\"Thursday 1 October 2026\"", "a date label is only quoted")
    expect(CSVCell.text(""), "\"\"", "an empty label is an empty cell")
    let awkward = "say \"hi\", then\nleave"
    expect(readCSVLine("x," + CSVCell.text(awkward) + ",1"), ["x", awkward, "1"],
           "quotes are doubled, so commas, quotes and line breaks come back exactly")
    expect(CSVCell.text("a\"b"), "\"a\"\"b\"", "a quote is doubled, not changed into another character")
}

// MARK: - The cap field cannot crash the app

private func checkCapInput() {
    let largest = CapInput.largestBytes
    expect(largest, 100_000_000_000_000, "the largest cap is 100,000 GB")
    let cases: [(String, Int64)] = [
        ("9223372037", largest),                        // trapped in Int64 before the fix
        ("9223372036854775807", largest),
        ("99999999999999999999999999999999", largest),  // too long even for Int64 to parse
        ("100000", largest), ("100001", largest),
        ("100", 100_000_000_000), (" 100 GB ", 100_000_000_000), ("100gb", 100_000_000_000),
        ("1.5", 1_500_000_000), ("1,000", 1_000_000_000_000), ("0", 0), ("", 0),
        ("-5", 0), ("+5", 0), ("abc", 0), ("inf", 0), ("nan", 0), ("1e5", 0), (".", 0), ("1.2.3", 0),
        ("GB", 0), ("١٠٠", 0),
    ]
    for (typed, bytes) in cases {
        expect(CapInput.bytes(fromText: typed), bytes, "the cap typed as \(typed.debugDescription)")
    }
    // Whatever is typed, the answer is in range: reaching the end is the proof
    // that nothing trapped on the way.
    var inRange = true
    for length in 1...40 {
        for digit in ["9", "1", "5"] {
            let value = CapInput.bytes(fromText: String(repeating: digit, count: length))
            inRange = inRange && value >= 0 && value <= largest
        }
    }
    check(inRange, "every long run of digits gives a cap in range, with no trap")
    for typed in ["1", "1.5", "100", "100000", "0.25"] {
        expect(CapInput.text(forBytes: CapInput.bytes(fromText: typed)), typed, "the field shows \(typed) back as typed")
    }
    expect(CapInput.bytes(fromText: String(repeating: "9", count: 400)), largest, "400 digits clamp to the largest, not to no cap")
    expect(CapInput.bytes(fromText: "1" + String(repeating: "0", count: 399) + ".5"), largest, "with a fraction after them too")
    expect(CapInput.bytes(fromText: "000000000000000000000100"), 100_000_000_000, "leading zeros mean nothing")
    expect(CapInput.bytes(fromText: "100000.5"), largest, "the largest plus a fraction is the largest")
    expect(CapInput.bytes(fromText: "0.001"), 1_000_000, "0.001 GB is 1 MB")
    expect(CapInput.text(forBytes: 1_000_000), "0.001", "and the field shows 0.001, what was stored")
    expect(CapInput.bytes(fromText: "1.0000000005"), 1_000_000_001, "a fraction is exact to the byte, rounded on the tenth digit")
    for typed in ["0.001", "0.000000001", "12.345678901", "99999.999999999", "0.5", "7"] {
        expect(CapInput.text(forBytes: CapInput.bytes(fromText: typed)), typed, "the field shows \(typed) back exactly as stored")
    }
    var agrees = true
    for stored: Int64 in [1, 999, 1_000_000, 1_500_000_000, 123_456_789_012, 99_999_999_999_999, largest] {
        agrees = agrees && CapInput.bytes(fromText: CapInput.text(forBytes: stored)) == stored
    }
    check(agrees, "whatever is stored, what the field shows reads back as the same figure")
    expect(CapInput.text(forBytes: 0), "", "no cap shows an empty field")
    expect(CapInput.text(forBytes: .max), "100000", "a wild saved figure shows as the largest")
    expect(CapInput.clamp(.max), largest, "a saved figure above the range is brought down")
    expect(CapInput.clamp(-5), 0, "a negative saved figure is no cap")
}

// MARK: - When a Wi-Fi network name may be read

private func checkNetworkNameRules() {
    typealias S = NetworkNames.Status
    let permissions: [NetworkNamePermission?] = [nil, .notAsked, .allowed, .denied, .restricted]
    // Every combination of the box, what macOS has said, and a question in flight.
    let table: [(Bool, NetworkNamePermission?, Bool, S)] = [
        (false, nil, false, .off), (false, .notAsked, false, .off), (false, .allowed, false, .off),
        (false, .denied, false, .refused), (false, .restricted, false, .restricted),
        (true, nil, false, .unchecked), (true, .notAsked, false, .notAskedYet), (true, .notAsked, true, .asking),
        (true, .allowed, false, .recording), (true, .allowed, true, .recording),
        (true, .denied, false, .refused), (true, .restricted, false, .restricted),
    ]
    for (ticked, permission, asking, status) in table {
        expect(NetworkNames.status(boxTicked: ticked, permission: permission, asking: asking), status,
               "box \(ticked ? "on" : "off"), permission \(String(describing: permission)), asking \(asking)")
    }

    // The gate: a name is read only with the box on and macOS saying yes.
    for ticked in [false, true] {
        for permission in permissions {
            expect(NetworkNames.shouldRead(boxTicked: ticked, permission: permission), ticked && permission == .allowed,
                   "reading with the box \(ticked ? "on" : "off") and \(String(describing: permission))")
        }
    }
    // macOS is asked only when it has never answered.
    for permission: NetworkNamePermission in [.notAsked, .allowed, .denied, .restricted] {
        expect(NetworkNames.asksOnTick(permission), permission == .notAsked, "ticking asks only if never asked: \(permission)")
        expect(NetworkNames.keepsBoxTicked(permission), permission == .notAsked || permission == .allowed,
               "a refusal or a restriction switches the box off: \(permission)")
    }
    let actions: [(S, NetworkNames.Action?)] = [
        (.off, nil), (.recording, nil), (.asking, .ask), (.notAskedYet, .ask), (.refused, .openSettings),
        (.restricted, nil), (.unchecked, nil),
    ]
    for (status, action) in actions {
        expect(NetworkNames.action(status), action, "the Preferences button for \(status)")
    }

    // The words describe what really happens.
    expect(NetworkNames.preferencesNote(.off), nil, "nothing to report while off")
    let refused = NetworkNames.preferencesNote(.refused) ?? ""
    check(["Switched off", "System Settings", "Privacy & Security", "Location Services", "Bytemeter", "tick this box again"]
            .allSatisfy(refused.contains), "a refusal says plainly where to grant it: \(refused)")
    check((NetworkNames.preferencesNote(.restricted) ?? "").contains("restricted"), "a restriction is named")
    check((NetworkNames.preferencesNote(.notAskedYet) ?? "").contains("not being recorded"),
          "an unasked copy says names are not being recorded")
    check(NetworkNames.preferencesCaption.contains("ticking this asks")
          && NetworkNames.preferencesCaption.contains("does not use Location Services"),
          "the caption says when macOS is asked and that off means untouched")
    check(NetworkNames.dashboardNote(.off).contains("is off") && NetworkNames.dashboardNote(.off).contains("Location Services"),
          "the dashboard says recording is off and why it would need Location Services")
    check(NetworkNames.dashboardNote(.notAskedYet).contains("not yet allowed"),
          "the dashboard does not claim names are recorded before macOS allows it")
    check(NetworkNames.dashboardNote(.recording).contains(NetworkNames.notRecorded)
          && NetworkNames.dashboardNote(.recording).contains(NetworkNames.unknown),
          "the dashboard explains both placeholders it can list")
    expect(NetworkNames.displayName(ssidPlaceholder), "Not recorded", "the placeholder is shown in words")
    expect(NetworkNames.displayName("Home"), "Home", "a real name is shown as it is")
    expect(CSVCell.text(NetworkNames.displayName(ssidPlaceholder)), "\"Not recorded\"",
           "so the placeholder reaches the export as words, not as a bare minus sign")
}
