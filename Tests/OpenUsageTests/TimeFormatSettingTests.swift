import Foundation
import XCTest
@testable import OpenUsage

final class TimeFormatSettingTests: XCTestCase {
    private var afternoon: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 17, minute: 30))!
    }

    func testLegacyExplicitHourCyclesOverrideLocaleDefault() {
        XCTAssertTrue(TimeFormatSetting.twelveHour.legacyShortTime(afternoon, base: Locale(identifier: "en_GB")).contains("5:30"))
        XCTAssertEqual(TimeFormatSetting.twentyFourHour.legacyShortTime(afternoon, base: Locale(identifier: "en_US")), "17:30")
    }

    func testLegacyAutoHonorsLocalizedShortTime() {
        for identifier in ["en_US", "en_GB", "zh_CN", "de_DE"] {
            let base = Locale(identifier: identifier)
            let expected = DateFormatter()
            expected.locale = base
            expected.timeStyle = .short
            XCTAssertEqual(TimeFormatSetting.auto.legacyShortTime(afternoon, base: base), expected.string(from: afternoon))
        }
    }

    func testLegacyTwelveHourTimePreservesChineseDayPeriod() {
        let text = TimeFormatSetting.twelveHour.legacyShortTime(afternoon, base: Locale(identifier: "zh_CN"))
        XCTAssertTrue(text.contains("5:30"))
        XCTAssertTrue(text.contains("下午"))
    }
}
