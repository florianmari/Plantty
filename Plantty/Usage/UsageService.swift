import Foundation
import Observation

/// UserDefaults key: show the Claude / Codex usage chips (and fetch at all).
let showUsageKey = "showUsage"

/// Reads Claude Code's and Codex's own sign-ins and fetches plan usage every few minutes.
/// Tokens are only held in memory for a request. Plantty never renews them: renewing
/// rotates the refresh token and would sign Claude Code / Codex out.
@MainActor @Observable final class UsageService {
    static let shared = UsageService()

    /// Providers with a sign-in on this Mac, in display order.
    private(set) var available: [UsageProvider] = []
    private(set) var reports: [UsageProvider: UsageReport] = [:]
    private(set) var errors: [UsageProvider: String] = [:]
    private(set) var isRefreshing = false
    /// True while the usage panel is open, so an auto-hidden sidebar stays put.
    var isPanelOpen = false

    @ObservationIgnored private var timer: Timer?
    private static let interval: TimeInterval = 5 * 60

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in
            Task { @MainActor in UsageService.shared.refresh() }
        }
    }

    /// Refreshes when the last result is older than `maxAge` (used when the panel opens).
    func refreshIfStale(maxAge: TimeInterval = 60) {
        let newest = reports.values.map(\.fetchedAt).max() ?? .distantPast
        if Date().timeIntervalSince(newest) > maxAge { refresh() }
    }

    func refresh() {
        guard !isRefreshing, UserDefaults.standard.object(forKey: showUsageKey) as? Bool ?? true else { return }
        isRefreshing = true
        Task {
            var found: [UsageProvider] = []
            for provider in UsageProvider.allCases {
                // Sign-in reading shells out to `security`; keep it off the main thread.
                guard let result = await Task.detached(operation: { await Self.fetch(provider) }).value else {
                    reports[provider] = nil
                    errors[provider] = nil
                    continue
                }
                found.append(provider)
                switch result {
                case .success(let report):
                    reports[provider] = report
                    errors[provider] = nil
                case .failure(let error):
                    errors[provider] = error.message
                }
            }
            available = found
            isRefreshing = false
        }
    }

    // MARK: Fetching

    struct Failure: Error { let message: String }

    /// Nil when there is no sign-in for the provider on this Mac.
    nonisolated static func fetch(_ provider: UsageProvider) async -> Result<UsageReport, Failure>? {
        switch provider {
        case .claude:
            guard let signIn = claudeSignIn() else { return nil }
            if let expiry = signIn.expiresAt, expiry < Date() {
                return .failure(Failure(message: "Claude Code's sign-in has expired. Run claude once to renew it."))
            }
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.setValue("Bearer \(signIn.token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            // The usage endpoint serves Claude Code's OAuth clients.
            request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
            return await load(request, tool: "claude") { try UsageParse.claude($0, email: signIn.email, plan: signIn.plan) }
        case .codex:
            guard let signIn = codexSignIn() else { return nil }
            var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
            request.setValue("Bearer \(signIn.token)", forHTTPHeaderField: "Authorization")
            request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
            request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
            request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
            if let account = signIn.account { request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id") }
            return await load(request, tool: "codex") { try UsageParse.codex($0) }
        }
    }

    private nonisolated static func load(
        _ request: URLRequest, tool: String, parse: (Data) throws -> UsageReport
    ) async -> Result<UsageReport, Failure> {
        var request = request
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300:
                do { return .success(try parse(data)) } catch {
                    return .failure(Failure(message: "The usage response changed format and couldn't be read."))
                }
            case 401, 403:
                return .failure(Failure(message: "Signed out or sign-in expired. Run \(tool) once to renew it."))
            case 429:
                return .failure(Failure(message: "Too many requests. Will retry on the next refresh."))
            default:
                return .failure(Failure(message: "The usage service answered with HTTP \(status)."))
            }
        } catch {
            return .failure(Failure(message: "Couldn't reach the usage service (\(error.localizedDescription))."))
        }
    }

    // MARK: Sign-ins

    private struct SignIn {
        var token: String
        var account: String?
        var email: String?
        var plan: String?
        var expiresAt: Date?
    }

    /// Claude Code keeps its sign-in in the login Keychain (via `security`, so reading it the same
    /// way needs no extra Keychain prompt), else in `~/.claude/.credentials.json`.
    private nonisolated static func claudeSignIn() -> SignIn? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let keychain = [NSUserName(), nil].lazy.compactMap { account -> Data? in
            var args = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
            if let account { args += ["-a", account] }
            return run("/usr/bin/security", args)
        }.first
        guard let data = keychain ?? (try? Data(contentsOf: home.appending(path: ".claude/.credentials.json"))),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let profile = (try? Data(contentsOf: home.appending(path: ".claude.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let email = (profile?["oauthAccount"] as? [String: Any])?["emailAddress"] as? String
        let expiresAt = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 > 1e11 ? $0 / 1000 : $0) }
        return SignIn(token: token, email: email,
                      plan: UsageParse.claudePlan(subscription: oauth["subscriptionType"] as? String,
                                                  tier: oauth["rateLimitTier"] as? String),
                      expiresAt: expiresAt)
    }

    /// The Codex CLI's ChatGPT sign-in. An API-key login has no plan usage.
    private nonisolated static func codexSignIn() -> SignIn? {
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
        guard let data = try? Data(contentsOf: codexHome.appending(path: "auth.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else { return nil }
        return SignIn(token: token, account: tokens["account_id"] as? String)
    }

    /// Runs a tool and returns its stdout, or nil on failure. Bounded so a stuck prompt can't hang refreshes.
    private nonisolated static func run(_ tool: String, _ args: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate(); return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return process.terminationStatus == 0 && !data.isEmpty ? data : nil
    }
}
