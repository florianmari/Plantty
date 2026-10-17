import XCTest

final class UsageModelTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testClaudeLimitsWithScopedModelBreakdownAndSpend() throws {
        let json = """
        {"limits":[
          {"kind":"session","percent":21,"resets_at":"2027-01-15T10:00:00.000Z"},
          {"kind":"weekly_all","percent":5,"resets_at":1800250000},
          {"kind":"weekly_scoped","percent":0,"resets_at":1800250000000,"scope":{"model":{"display_name":"Fable"}}},
          {"kind":"something_new","percent":50}],
         "seven_day_breakdown":{"rows":[{"display_name":"Claude Code","percent":71},{"display_name":"Chats","percent":29},{"display_name":"API","percent":0}]},
         "spend":{"enabled":true,"used":{"amount_minor":1234,"currency":"EUR","exponent":2},"limit":{"amount_minor":5000,"currency":"EUR","exponent":2}}}
        """
        let r = try UsageParse.claude(Data(json.utf8), email: "a@b.c", plan: "Max 5x", now: now)
        XCTAssertEqual(r.windows.map(\.title), ["Session", "Weekly", "Fable"])
        XCTAssertEqual(r.windows.map(\.left), [79, 95, 100])
        XCTAssertEqual(r.windows[1].resetsAt, Date(timeIntervalSince1970: 1_800_250_000))
        XCTAssertEqual(r.windows[2].resetsAt, Date(timeIntervalSince1970: 1_800_250_000), "milliseconds are understood")
        XCTAssertNotNil(r.windows[0].resetsAt)
        XCTAssertEqual(r.shares, [.init(name: "Claude Code", percent: 71), .init(name: "Chats", percent: 29)])
        XCTAssertEqual(r.facts.first?.value, "12.34 EUR of 50.00 EUR")
        XCTAssertEqual(r.tightest?.title, "Session")
    }

    func testClaudeFallsBackToFixedWindowsAndSpendOff() throws {
        let json = #"{"five_hour":{"utilization":40.4,"resets_at":"2027-01-15T10:00:00Z"},"seven_day":{"utilization":10},"spend":{"enabled":false}}"#
        let r = try UsageParse.claude(Data(json.utf8), email: nil, plan: nil)
        XCTAssertEqual(r.windows.map(\.title), ["Session", "Weekly"])
        XCTAssertEqual(r.windows.map(\.left), [60, 90])
        XCTAssertEqual(r.facts.first?.value, "Off")
    }

    func testCodexClassifiesWindowsByLength() throws {
        // Slots swapped on purpose: the length decides.
        let json = """
        {"email":"x@y.z","plan_type":"plus",
         "rate_limit":{"primary_window":{"used_percent":12,"limit_window_seconds":604800,"reset_at":1800300000},
                       "secondary_window":{"used_percent":55,"limit_window_seconds":18000,"reset_at":1800010000}},
         "credits":{"unlimited":false,"balance":"3.50"}}
        """
        let r = try UsageParse.codex(Data(json.utf8))
        XCTAssertEqual(r.windows.map(\.title), ["Weekly", "Session"])
        XCTAssertEqual(r.plan, "Plus")
        XCTAssertEqual(r.tightest?.title, "Session")
        XCTAssertEqual(r.facts.first?.value, "3.50")

        let none = try UsageParse.codex(Data(#"{"credits":{"unlimited":false,"balance":"0"}}"#.utf8))
        XCTAssertTrue(none.facts.isEmpty)
    }

    func testPaceReserveAndRunsOut() {
        // 5h session, 3h elapsed (60% expected), 21% used → 39% in reserve, lasts.
        let w = UsageWindow(title: "Session", used: 21, resetsAt: now.addingTimeInterval(2 * 3600), length: UsageWindow.session)
        let pace = w.pace(now: now)!
        XCTAssertEqual(pace.expected, 60, accuracy: 0.01)
        XCTAssertNil(pace.runsOut)
        XCTAssertEqual(pace.describe(used: w.used), "39% in reserve · Lasts until reset")

        // 1h elapsed, 50% used → runs out 1h from now, before the 4h reset.
        let fast = UsageWindow(title: "Session", used: 50, resetsAt: now.addingTimeInterval(4 * 3600), length: UsageWindow.session)
        XCTAssertEqual(fast.pace(now: now)!.describe(used: 50), "30% in deficit · Runs out in 1h 0m")
        XCTAssertEqual(Pace(expected: 10, runsOut: nil).describe(used: 100), "Ran out")
    }

    func testCountdownAndPlanNames() {
        XCTAssertEqual(countdown(122 * 60), "2h 2m")
        XCTAssertEqual(countdown(2 * 86400 + 22 * 3600), "2d 22h")
        XCTAssertEqual(countdown(30), "1m")
        XCTAssertEqual(UsageParse.claudePlan(subscription: "max", tier: "default_claude_max_5x"), "Max 5x")
        XCTAssertEqual(UsageParse.claudePlan(subscription: "pro", tier: "default_claude_ai"), "Pro")
        XCTAssertNil(UsageParse.claudePlan(subscription: nil, tier: nil))
    }
}
