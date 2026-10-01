import XCTest
@testable import OpenUsage

/// Crash reporting remains mandatory even when optional provider analytics are disabled.
final class TelemetrySinkTests: XCTestCase {
    func testErrorAutocaptureStaysEnabledRegardlessOfOptionalAnalytics() {
        XCTAssertTrue(
            PostHogTelemetrySink.errorAutocaptureEnabled(optionalAnalyticsEnabled: true),
            "crash autocapture must stay on when optional analytics are enabled"
        )
        XCTAssertTrue(
            PostHogTelemetrySink.errorAutocaptureEnabled(optionalAnalyticsEnabled: false),
            "crash autocapture must stay on when optional analytics are disabled"
        )
    }

    func testUnofficialBuildSwitchDisablesTelemetryEvenWithAnOverride() {
        let disabled = [TelemetryConfig.disabledInfoKey: true]
        XCTAssertEqual(TelemetryConfig.token(info: disabled, environment: [:]), TelemetryConfig.placeholderToken)
        XCTAssertEqual(
            TelemetryConfig.token(info: disabled, environment: ["OPENUSAGE_POSTHOG_TOKEN": "phc_override"]),
            TelemetryConfig.placeholderToken
        )
        XCTAssertFalse(TelemetryConfig.isUsable(TelemetryConfig.token(info: disabled, environment: [:])))
    }

    func testOfficialBuildsKeepTheBakedTokenAndLocalOverride() {
        XCTAssertTrue(TelemetryConfig.isUsable(TelemetryConfig.token(info: [:], environment: [:])))
        XCTAssertTrue(TelemetryConfig.isUsable(TelemetryConfig.token(
            info: [TelemetryConfig.disabledInfoKey: false], environment: [:]
        )))
        XCTAssertEqual(
            TelemetryConfig.token(info: [:], environment: ["OPENUSAGE_POSTHOG_TOKEN": " phc_override "]),
            "phc_override"
        )
    }
}
