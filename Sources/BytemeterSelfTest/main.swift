import Foundation

// A plain executable rather than XCTest: XCTest cannot be resolved with the
// Command Line Tools alone, and this must run without full Xcode. The checks below are the
// real ones, covering the counting rules that have to be right.
//
// Each check is a function in the file for its subject (LedgerChecks.swift,
// DatabaseChecks.swift and the rest), and the helpers they share are in
// Harness.swift. They run here in the order they were written.

checkOrdinaryReadingBooksItsDelta()
checkFirstSightIsABaseline()
checkResetBooksNoSpike()
checkThirtyTwoBitWrapIsCarried()
checkFarFallIsAResetNotAWrap()
checkSleepGapIsSpreadWhole()
checkRelaunchRecoversTheGap()
checkOnlyPhysicalInterfacesCount()
checkUnitsAreDecimal()
checkNoFigureReadsAsAThousand()
checkBucketsAddUpOnConflict()
checkBaselinesRoundTrip()
checkPruningLosesNoByte()
checkWeekStartsOnMonday()
checkTopTalkersRankByTotal()
checkStatusModesCycle()
checkOnlySpreadRowsAreEstimated()
checkMeasuredBytesNeverClearTheMark()
checkMinuteKeepsItsEstimatedBytes()
checkVersion2MarksOnlySpreadRows()
checkVersion3KeepsEveryFigure()
checkPruningKeepsTheMark()
checkPruningKeepsEstimatedBytesExactly()
checkShapedViewsCarryTheEstimate()
checkRestartBooksBytesSinceBoot()
checkIdleInterfaceSaysNothingAcrossRestart()
checkRestartIsDecidedFirst()
checkCounterSourceIsPerReading()
checkFailedWriteMovesNothing()
checkSkippedMidnightsKeepEachDay()
checkClockChangeHoursKeepTheirSlot()
checkPruningKeepsLocalHoursInEveryZone()
checkClockSetBackwardsBooksNothingInThePast()
checkMonthByMonthKeepsTheNewestMonths()
checkClockThatStaysWrongBooksNothingInThePast()
checkAveragesCountFromWhenCountingBegan()
checkProjectionOnACyclesFirstDay()
checkHeatmapAveragesWholeWeeks()
checkSevenDayAverageCountsWholeDays()
checkTodayAgainstYesterdayAtThisTime()
checkYesterdayUntilStaysInYesterday()
checkTwoProcessesCanMigrateAtOnce()
checkReadingBeforeSleep()
checkProcessTallyDeltas()
checkPerAppRowsAreHeld()
checkSleepSpreadIsIdle()
checkWriteReadingCounterSourceAndRollback()
checkAllTimeIsTheSumOfSamples()
checkAsOfAMomentMatchesThatMoment()
checkHeadlinesAreOneSet()
checkRecentEventsStopAtTheMoment()
checkReadOnlyOpenChangesNothing()
checkCapSaysWhatIsLeftOrOver()
checkMonthByMonthNamesItsPeriods()
checkMenuSaysWhenRecordingStops()
runAppChecks()
runDashboardChecks()

// MARK: - Result

try? FileManager.default.removeItem(atPath: scratchFolder)
print("Bytemeter self-test: \(checksRun) checks run, \(failures.count) failed.")
for failure in failures { print("  FAILED: \(failure)") }
exit(failures.isEmpty ? 0 : 1)
