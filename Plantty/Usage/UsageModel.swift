import Foundation

// Plan-usage reading for Claude Code and Codex. Endpoints and response shapes follow
// CodexBar (MIT, github.com/steipete/CodexBar) as ported by herdr-gpui. These are the
// services' own private endpoints, so a format change can break them without notice.

enum UsageProvider: String, CaseIterable, Identifiable {
    case codex, claude

    var id: String { rawValue }
    var name: String { self == .claude ? "Claude" : "Codex" }
    var symbol: String { self == .claude ? "asterisk" : "chevron.left.forwardslash.chevron.right" }
    var dashboard: URL {
        URL(string: self == .claude ? "https://claude.ai/settings/usage" : "https://chatgpt.com/codex/settings/usage")!
    }
    var statusPage: URL {
        URL(string: self == .claude ? "https://status.anthropic.com" : "https://status.openai.com")!
    }
}

/// One rate limit, e.g. the 5-hour session or the weekly window.
struct UsageWindow: Equatable {
    static let session: TimeInterval = 5 * 3600
    static let week: TimeInterval = 7 * 86400

    var title: String
    /// Percent used, 0–100.
    var used: Double
    var resetsAt: Date?
    var length: TimeInterval?

    init(title: String, used: Double, resetsAt: Date?, length: TimeInterval?) {
        self.title = title
        self.used = min(max(used, 0), 100)
        self.resetsAt = resetsAt
        self.length = length
    }

    var left: Int { 100 - min(Int(used.rounded()), 100) }

    /// How use so far compares with an even spend across the window.
    func pace(now: Date) -> Pace? {
        guard let resetsAt, let length, length > 0 else { return nil }
        let remaining = max(resetsAt.timeIntervalSince(now), 0)
        let elapsed = length - remaining
        guard elapsed > 0 else { return nil }
        var runsOut: TimeInterval?
        if used > 0, used < 100 {
            let toEmpty = elapsed * (100 - used) / used
            if toEmpty < remaining { runsOut = toEmpty }
        }
        return Pace(expected: min(elapsed / length * 100, 100), runsOut: runsOut)
    }
}

struct Pace: Equatable {
    /// Percent an even spend would have used by now.
    var expected: Double
    /// When the window runs out at the rate used so far, if before it resets.
    var runsOut: TimeInterval?

    /// `38% in reserve · Lasts until reset`, as CodexBar puts it.
    func describe(used: Double) -> String {
        if used >= 100 { return "Ran out" }
        let margin = expected - used
        let standing = margin >= 0.5 ? "\(Int(margin.rounded()))% in reserve"
            : margin <= -0.5 ? "\(Int((-margin).rounded()))% in deficit"
            : "On pace"
        let outlook = runsOut.map { "Runs out in \(countdown($0))" } ?? "Lasts until reset"
        return "\(standing) · \(outlook)"
    }
}

struct UsageReport: Equatable {
    struct Share: Equatable { var name: String; var percent: Double }

    var provider: UsageProvider
    var email: String?
    var plan: String?
    var windows: [UsageWindow]
    var shares: [Share] = []
    /// Short facts such as extra usage or credits: (section title, label, value).
    var facts: [(section: String, label: String, value: String)] = []
    var fetchedAt = Date()

    /// The window closest to running out, shown on the chip.
    var tightest: UsageWindow? { windows.min { $0.left < $1.left } }

    static func == (a: UsageReport, b: UsageReport) -> Bool {
        a.provider == b.provider && a.email == b.email && a.plan == b.plan && a.windows == b.windows
            && a.shares == b.shares && a.facts.map { "\($0)" } == b.facts.map { "\($0)" }
    }
}

/// `2h 2m`, `2d 22h`, `5m`.
func countdown(_ interval: TimeInterval) -> String {
    let minutes = Int((max(interval, 0) / 60).rounded(.up))
    let (days, hours, mins) = (minutes / 1440, minutes / 60 % 24, minutes % 60)
    if days > 0 { return "\(days)d \(hours)h" }
    if hours > 0 { return "\(hours)h \(mins)m" }
    return "\(mins)m"
}

// MARK: - Parsing

enum UsageParse {
    /// Claude's `/api/oauth/usage` response.
    static func claude(_ data: Data, email: String?, plan: String?, now: Date = Date()) throws -> UsageReport {
        let usage = try JSONDecoder().decode(ClaudeUsage.self, from: data)
        var windows: [UsageWindow] = (usage.limits ?? []).compactMap { limit in
            guard let used = limit.percent else { return nil }
            let title: String
            switch limit.kind {
            case "session": title = "Session"
            case "weekly_all": title = "Weekly"
            case "weekly_scoped":
                guard let name = limit.scope?.model?.display_name?.trimmingCharacters(in: .whitespaces),
                      !name.isEmpty else { return nil }
                title = name
            default: return nil
            }
            return UsageWindow(title: title, used: used, resetsAt: limit.resets_at?.date,
                               length: limit.kind == "session" ? UsageWindow.session : UsageWindow.week)
        }
        if windows.isEmpty {
            windows = [("Session", usage.five_hour, UsageWindow.session), ("Weekly", usage.seven_day, UsageWindow.week)]
                .compactMap { title, window, length in
                    guard let used = window?.utilization else { return nil }
                    return UsageWindow(title: title, used: used, resetsAt: window?.resets_at?.date, length: length)
                }
        }
        var report = UsageReport(provider: .claude, email: email, plan: plan, windows: windows, fetchedAt: now)
        report.shares = (usage.seven_day_breakdown?.rows ?? []).compactMap { row in
            guard let name = row.display_name, let percent = row.percent, percent > 0 else { return nil }
            return .init(name: name, percent: percent)
        }
        if let spend = usage.spend {
            let value: String
            if spend.enabled == true {
                switch (spend.used?.text, spend.limit?.text) {
                case let (used?, limit?): value = "\(used) of \(limit)"
                case let (used?, nil): value = used
                default: value = "On"
                }
                report.facts.append(("Extra usage", "This month", value))
            } else {
                report.facts.append(("Extra usage", "Status", "Off"))
            }
        }
        return report
    }

    /// Codex's `/backend-api/wham/usage` response.
    static func codex(_ data: Data, now: Date = Date()) throws -> UsageReport {
        let usage = try JSONDecoder().decode(CodexUsage.self, from: data)
        var windows = usage.rate_limit?.windows() ?? []
        if let review = usage.code_review_rate_limit?.windows().first {
            windows.append(UsageWindow(title: "Code review", used: review.used, resetsAt: review.resetsAt, length: review.length))
        }
        let plan = usage.plan_type.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        var report = UsageReport(provider: .codex, email: usage.email, plan: plan, windows: windows, fetchedAt: now)
        if let credits = usage.credits {
            if credits.unlimited == true {
                report.facts.append(("Credits", "Balance", "Unlimited"))
            } else if let balance = credits.balance, Double(balance) != 0 { // a zero balance is just noise on plans without credits
                report.facts.append(("Credits", "Balance", balance))
            }
        }
        return report
    }

    /// `max` on tier `default_claude_max_20x` is `Max 20x`.
    static func claudePlan(subscription: String?, tier: String?) -> String? {
        guard let subscription = subscription?.trimmingCharacters(in: .whitespaces), !subscription.isEmpty else { return nil }
        let name = subscription.prefix(1).uppercased() + subscription.dropFirst()
        if let last = tier?.split(separator: "_").last, last.hasSuffix("x"),
           last.dropLast().allSatisfy(\.isNumber), last.count > 1 {
            return "\(name) \(last)"
        }
        return name
    }
}

// MARK: - Response shapes

/// A time sent as seconds or milliseconds since 1970, or as ISO 8601 text.
struct FlexibleDate: Decodable {
    let date: Date?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let number = try? c.decode(Double.self) {
            date = Self.epoch(number)
        } else if let text = try? c.decode(String.self) {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if let number = Double(trimmed) {
                date = Self.epoch(number)
            } else {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                date = iso.date(from: trimmed) ?? ISO8601DateFormatter().date(from: trimmed)
            }
        } else {
            date = nil
        }
    }

    private static func epoch(_ value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 1e11 ? value / 1000 : value)
    }
}

private struct ClaudeUsage: Decodable {
    struct Limit: Decodable {
        struct Scope: Decodable { struct Model: Decodable { var display_name: String? }; var model: Model? }
        var kind: String
        var percent: Double?
        var resets_at: FlexibleDate?
        var scope: Scope?
    }
    struct Fixed: Decodable { var utilization: Double?; var resets_at: FlexibleDate? }
    struct Breakdown: Decodable {
        struct Row: Decodable { var display_name: String?; var percent: Double? }
        var rows: [Row]
    }
    struct Spend: Decodable {
        struct Money: Decodable {
            var amount_minor: Int
            var currency: String
            var exponent: Int

            /// `12.34 EUR`, in the currency's own minor units.
            var text: String? {
                let exp = min(max(exponent, 0), 6)
                let value = Decimal(amount_minor) / pow(10, exp)
                let formatter = NumberFormatter()
                formatter.minimumFractionDigits = exp
                formatter.maximumFractionDigits = exp
                formatter.minimumIntegerDigits = 1
                formatter.usesGroupingSeparator = false
                formatter.decimalSeparator = "."
                return formatter.string(from: value as NSDecimalNumber).map { "\($0) \(currency.trimmingCharacters(in: .whitespaces))" }
            }
        }
        var enabled: Bool?
        var used: Money?
        var limit: Money?
    }
    var limits: [Limit]?
    var five_hour: Fixed?
    var seven_day: Fixed?
    var seven_day_breakdown: Breakdown?
    var spend: Spend?
}

private struct CodexUsage: Decodable {
    struct Window: Decodable {
        var used_percent: Double
        var limit_window_seconds: Double?
        var reset_at: FlexibleDate?
    }
    struct Limits: Decodable {
        var primary_window: Window?
        var secondary_window: Window?

        /// A window is known by its length; the slot it arrives in only decides when the length is unfamiliar.
        func windows() -> [UsageWindow] {
            [("Session", primary_window), ("Weekly", secondary_window)].compactMap { slot, window in
                guard let window else { return nil }
                let length = window.limit_window_seconds
                let title = length.map { abs($0 - UsageWindow.session) <= 60 ? "Session" : abs($0 - UsageWindow.week) <= 60 ? "Weekly" : slot } ?? slot
                return UsageWindow(title: title, used: window.used_percent, resetsAt: window.reset_at?.date, length: length)
            }
        }
    }
    struct Credits: Decodable { var unlimited: Bool?; var balance: String? }
    var email: String?
    var plan_type: String?
    var rate_limit: Limits?
    var code_review_rate_limit: Limits?
    var credits: Credits?
}
