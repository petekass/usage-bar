import SwiftUI
import AppKit
import os

// MARK: - Models

let usageStalenessThreshold: TimeInterval = 300

/// "as of" label for stale data; adds the date once it is older than a day,
/// so a snapshot from last week doesn't read like one from last night.
func staleLabel(_ d: Date, now: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = now.timeIntervalSince(d) > 86_400 ? "MMM d, HH:mm" : "HH:mm"
    return "as of \(f.string(from: d))"
}

private let authLog = Logger(subsystem: "UsageBar", category: "auth")

struct ModelLimit: Codable {
    let name: String
    let percent: Double
    let reset: Date?
}

struct ProviderUsage: Codable {
    // nil = the provider does not report this window; the row is hidden
    var sessionPercent: Double?
    var sessionReset: Date?
    var weeklyPercent: Double?
    var weeklyReset: Date?
    var modelLimits: [ModelLimit] = []
    var error: String?
    var fetchedAt: Date?
    var shouldBackoff = false
    /// Why the shown data is not from this refresh (e.g. "Auth expired").
    /// Runtime only, never written to the shared cache.
    var staleReason: String?

    enum CodingKeys: String, CodingKey {
        case sessionPercent, sessionReset, weeklyPercent, weeklyReset, modelLimits, error, fetchedAt
    }
}

// Shared across processes (menu bar app + cmux Dock CLI instances) so only
// one of them actually hits the APIs per refresh interval.
struct CachedProvider: Codable {
    var usage: ProviderUsage
    var fetchedAt: Date
}

struct UsageCache: Codable {
    var claude: CachedProvider?
    var codex: CachedProvider?
    var gemini: CachedProvider?
}

struct AppState {
    var claude = ProviderUsage()
    var codex = ProviderUsage()
    var gemini = ProviderUsage()
    var lastUpdated: Date?
}

// MARK: - Claude API

struct ClaudeCredentials: Codable {
    struct OAuth: Codable {
        let accessToken: String
        let expiresAt: Int64?
    }
    let claudeAiOauth: OAuth

    var isExpired: Bool {
        guard let exp = claudeAiOauth.expiresAt else { return false }
        return Double(exp) / 1000 < Date().timeIntervalSince1970
    }
}

struct ClaudeUsageResponse: Codable {
    struct Limit: Codable {
        let usedPercent: Double?
        let utilization: Double?
        let resetsAt: String?
        enum CodingKeys: String, CodingKey { case usedPercent = "used_percent"; case utilization; case resetsAt = "resets_at" }
    }
    struct LimitEntry: Codable {
        struct Scope: Codable {
            struct Model: Codable {
                let displayName: String?
                enum CodingKeys: String, CodingKey { case displayName = "display_name" }
            }
            let model: Model?
        }
        let kind: String?
        let percent: Double?
        let resetsAt: String?
        let scope: Scope?
        enum CodingKeys: String, CodingKey { case kind, percent, scope; case resetsAt = "resets_at" }
    }
    let fiveHour: Limit?
    let sevenDay: Limit?
    let sessionRateLimit: Limit?
    let weeklyRateLimit: Limit?
    let limits: [LimitEntry]?
    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sessionRateLimit = "session_rate_limit"
        case weeklyRateLimit = "weekly_rate_limit"
        case limits
    }
}

struct ClaudeStatuslineCache: Codable {
    let claudeWeekly: String?
    let claudeSession: String?
    let weeklyReset: String?
    let sessionReset: String?
    let ts: Double
    enum CodingKeys: String, CodingKey {
        case claudeWeekly = "claude_weekly"
        case claudeSession = "claude_session"
        case weeklyReset = "weekly_reset"
        case sessionReset = "session_reset"
        case ts
    }
}

// MARK: - Codex API

struct CodexCredentials: Codable {
    struct Tokens: Codable {
        let accessToken: String
        let accountId: String
        enum CodingKeys: String, CodingKey { case accessToken = "access_token"; case accountId = "account_id" }
    }
    let tokens: Tokens
}

struct CodexUsageResponse: Codable {
    struct RateLimit: Codable {
        struct Window: Codable {
            let usedPercent: Int?
            let resetAt: Int64?
            let limitWindowSeconds: Int64?
            enum CodingKeys: String, CodingKey {
                case usedPercent = "used_percent"
                case resetAt = "reset_at"
                case limitWindowSeconds = "limit_window_seconds"
            }
        }
        let primaryWindow: Window?
        let secondaryWindow: Window?
        enum CodingKeys: String, CodingKey { case primaryWindow = "primary_window"; case secondaryWindow = "secondary_window" }
    }
    struct AdditionalRateLimit: Codable {
        let limitName: String?
        let rateLimit: RateLimit?
        enum CodingKeys: String, CodingKey { case limitName = "limit_name"; case rateLimit = "rate_limit" }
    }
    let rateLimit: RateLimit?
    let additionalRateLimits: [AdditionalRateLimit]?
    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
        case additionalRateLimits = "additional_rate_limits"
    }
}

// MARK: - Gemini API

struct AntigravityCredentials: Codable {
    struct Token: Codable {
        let accessToken: String
        let expiry: String?
        let refreshToken: String?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiry
            case refreshToken = "refresh_token"
        }
    }
    let token: Token
}

/// Antigravity's installed-app OAuth client, kept outside the repo in
/// ~/.config/usagebar/gemini-oauth-client.json (0600).
struct GoogleOAuthClient: Codable {
    let clientId: String
    let clientSecret: String
    enum CodingKeys: String, CodingKey { case clientId = "client_id"; case clientSecret = "client_secret" }
}

struct GoogleTokenResponse: Codable {
    let accessToken: String
    let expiresIn: Double?
    enum CodingKeys: String, CodingKey { case accessToken = "access_token"; case expiresIn = "expires_in" }
}

struct GeminiAuth {
    var token: String?
    var useDailyEndpoint: Bool
    var error: String?
    /// Refresh token of the source the access token came from, for a retry after a 401.
    var refreshToken: String?
}

struct GeminiCLICredentials: Codable {
    let accessToken: String
    let expiryDate: Int64?
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiryDate = "expiry_date"
    }

    var isExpired: Bool {
        guard let exp = expiryDate else { return false }
        return Double(exp) / 1000 < Date().timeIntervalSince1970
    }
}

struct GeminiQuotaResponse: Codable {
    struct Bucket: Codable {
        let modelId: String?
        let remainingFraction: Double?
        let resetTime: String?
    }
    let buckets: [Bucket]?
}

struct GeminiQuotaSummaryResponse: Codable {
    struct Group: Codable {
        struct Bucket: Codable {
            let bucketId: String?
            let displayName: String?
            let window: String?
            let remainingFraction: Double?
            let resetTime: String?
        }
        let displayName: String?
        let buckets: [Bucket]?
    }
    let groups: [Group]?
}

// MARK: - API Client

class UsageAPI {
    static let shared = UsageAPI()

    private var lastGoodClaude: ProviderUsage?
    private var lastGoodCodex: ProviderUsage?
    private var lastGoodGemini: ProviderUsage?
    private var claudeBackoff = Backoff()
    private var codexBackoff = Backoff()
    private var geminiBackoff = Backoff()
    /// Access token UsageBar minted itself from Antigravity's refresh token.
    /// Kept in memory only; T3's file and the Keychain item stay untouched.
    private var geminiRefreshed: (token: String, expiry: Date, refreshToken: String)?
    /// Access tokens the quota API answered with 403 (e.g. an `agy` login whose
    /// account has no Cloud Code access). Skipped until they rotate.
    private var geminiRejected: Set<String> = []

    private let cacheURL = URL(fileURLWithPath: NSHomeDirectory() + "/.cache/usagebar-state.json")
    // Serve from the shared cache while it is fresher than this, so N running
    // instances still produce only ~1 API request per interval in total.
    private let cacheMaxAge: TimeInterval = 55
    // Anthropic's usage endpoint rate-limits a token that is polled every
    // minute (429 with retry-after: 0, observed 2026-11-25 for 10+ minutes),
    // and the weekly numbers move slowly, so Claude is polled less often.
    private let claudeCacheMaxAge: TimeInterval = 175

    /// 429 backoff that doubles while the API keeps refusing: 5, 10, 20, 30 min.
    struct Backoff {
        var until = Date.distantPast
        var streak = 0
        mutating func hit() {
            streak += 1
            until = Date().addingTimeInterval(min(300 * pow(2, Double(streak - 1)), 1800))
        }
        mutating func reset() { streak = 0; until = .distantPast }
    }

    func fetchAll() async -> AppState {
        var state = AppState()
        state.lastUpdated = Date()
        let cache = readCache()

        // Do not let an older API result reintroduce model-scoped limits when
        // this process can only serve the auth-free statusline source.
        let auth = fetchClaudeAccessToken()
        if auth.token == nil,
           let local = fetchClaudeFromStatuslineCache(),
           let fetchedAt = local.fetchedAt {
            state.claude = local
            lastGoodClaude = local
            writeCache { $0.claude = CachedProvider(usage: local, fetchedAt: fetchedAt) }
        } else {
            state.claude = await fetchProvider(
                cached: cache?.claude, maxAge: claudeCacheMaxAge,
                lastGood: &lastGoodClaude, backoff: &claudeBackoff,
                fetch: { await self.fetchClaude(auth: auth) },
                store: { c in self.writeCache { $0.claude = c } })
        }
        state.codex = await fetchProvider(
            cached: cache?.codex, lastGood: &lastGoodCodex, backoff: &codexBackoff,
            fetch: fetchCodex, store: { c in self.writeCache { $0.codex = c } })
        state.gemini = await fetchProvider(
            cached: cache?.gemini, lastGood: &lastGoodGemini, backoff: &geminiBackoff,
            fetch: fetchGemini, store: { c in self.writeCache { $0.gemini = c } })

        return state
    }

    private func fetchProvider(cached: CachedProvider?,
                               maxAge: TimeInterval? = nil,
                               lastGood: inout ProviderUsage?,
                               backoff: inout Backoff,
                               fetch: () async -> ProviderUsage,
                               store: (CachedProvider) -> Void) async -> ProviderUsage {
        let now = Date()
        // Another instance fetched moments ago — reuse its result.
        if let c = cached, now.timeIntervalSince(c.fetchedAt) < (maxAge ?? cacheMaxAge) {
            var usage = c.usage
            usage.fetchedAt = usage.fetchedAt ?? c.fetchedAt
            lastGood = usage
            return usage
        }
        // Backing off after a 429 — show the best data we have.
        if now < backoff.until, var usage = lastGood ?? cached?.usage {
            usage.fetchedAt = usage.fetchedAt ?? cached?.fetchedAt
            usage.staleReason = "Rate limit"
            return usage
        }

        let fetched = await fetch()
        if fetched.shouldBackoff || fetched.error == "Rate limit" {
            backoff.hit()
        } else if fetched.error == nil {
            backoff.reset()
        }
        if fetched.error == nil {
            lastGood = fetched
            store(CachedProvider(usage: fetched, fetchedAt: fetched.fetchedAt ?? Date()))
            return fetched
        }
        // Transient errors keep the last good data (in-memory or from disk).
        if var usage = lastGood ?? cached?.usage {
            usage.fetchedAt = usage.fetchedAt ?? cached?.fetchedAt
            usage.staleReason = fetched.error
            return usage
        }
        return fetched
    }

    private func readCache() -> UsageCache? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
        return try? d.decode(UsageCache.self, from: data)
    }

    private func writeCache(_ update: (inout UsageCache) -> Void) {
        // Re-read and merge so concurrent instances don't clobber each other's slot.
        var cache = readCache() ?? UsageCache()
        update(&cache)
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970
        try? FileManager.default.createDirectory(atPath: NSHomeDirectory() + "/.cache",
                                                 withIntermediateDirectories: true)
        if let data = try? e.encode(cache) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    private func fetchClaude(auth: (token: String?, error: String?)) async -> ProviderUsage {
        var u = ProviderUsage()
        guard let token = auth.token else {
            u.error = auth.error ?? "No auth"
            return fetchClaudeFromStatuslineCache() ?? u
        }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                u.error = "Network"
                return fetchClaudeFromStatuslineCache() ?? u
            }
            guard http.statusCode == 200 else {
                u.error = http.statusCode == 429 ? "Rate limit" : "API \(http.statusCode)"
                if var local = fetchClaudeFromStatuslineCache() {
                    local.shouldBackoff = http.statusCode == 429
                    return local
                }
                return u
            }
            let r = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
            if let s = r.fiveHour ?? r.sessionRateLimit {
                u.sessionPercent = s.usedPercent ?? s.utilization ?? 0
                if let t = s.resetsAt { u.sessionReset = parseISO(t) }
            }
            if let w = r.sevenDay ?? r.weeklyRateLimit {
                u.weeklyPercent = w.usedPercent ?? w.utilization ?? 0
                if let t = w.resetsAt { u.weeklyReset = parseISO(t) }
            }
            // Model-scoped weekly limits (e.g. Fable/Opus) from the newer `limits` array
            for l in r.limits ?? [] where l.kind == "weekly_scoped" {
                guard let name = l.scope?.model?.displayName else { continue }
                u.modelLimits.append(ModelLimit(name: name,
                                                percent: l.percent ?? 0,
                                                reset: l.resetsAt.flatMap(parseISO)))
            }
            u.fetchedAt = Date()
            return u
        } catch {
            u.error = "Error"
            return fetchClaudeFromStatuslineCache() ?? u
        }
    }

    private func fetchClaudeFromStatuslineCache() -> ProviderUsage? {
        let path = NSHomeDirectory() + "/.claude/usage-cache.json"
        guard let data = FileManager.default.contents(atPath: path),
              let cache = try? JSONDecoder().decode(ClaudeStatuslineCache.self, from: data) else {
            return nil
        }
        let fetchedAt = Date(timeIntervalSince1970: cache.ts)
        guard Date().timeIntervalSince(fetchedAt) <= 900 else { return nil }

        var u = ProviderUsage()
        u.sessionPercent = cache.claudeSession.flatMap(Double.init)
        u.weeklyPercent = cache.claudeWeekly.flatMap(Double.init)
        u.sessionReset = cache.sessionReset.flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        u.weeklyReset = cache.weeklyReset.flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        u.fetchedAt = fetchedAt
        guard u.sessionPercent != nil || u.weeklyPercent != nil else { return nil }
        return u
    }

    private func fetchClaudeAccessToken() -> (token: String?, error: String?) {
        // Optional override: a dedicated token in a 0600 file.
        let tokenPath = NSHomeDirectory() + "/.config/usagebar/token"
        if let token = try? String(contentsOfFile: tokenPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            return (token, nil)
        }

        var error = "No auth"
        // Linux-style plaintext credentials, if Claude Code ever wrote them here.
        let path = NSHomeDirectory() + "/.claude/.credentials.json"
        if let data = FileManager.default.contents(atPath: path) {
            if let creds = try? JSONDecoder().decode(ClaudeCredentials.self, from: data) {
                if !creds.isExpired { return (creds.claudeAiOauth.accessToken, nil) }
                error = "Auth expired"
            } else {
                error = "Auth format"
            }
        }

        // macOS default: Claude Code's own login Keychain item.
        if let creds = readClaudeKeychainCredentials() {
            if !creds.isExpired { return (creds.claudeAiOauth.accessToken, nil) }
            error = "Auth expired"
        }
        return (nil, error)
    }

    /// Reads Claude Code's OAuth credentials from the login Keychain.
    ///
    /// Claude Code itself reads and writes this item through /usr/bin/security,
    /// so the item's access list trusts that tool. Asking the same tool for it
    /// therefore shows no authorization prompt, whichever binary spawns it (app
    /// bundle or --cli copy), and keeps working across token rotations. A direct
    /// SecItemCopyMatching call is checked against UsageBar's own code identity
    /// instead, which is what prompted on every rotation before.
    /// Only the access token is used; the refresh flow stays with Claude Code.
    private func readClaudeKeychainCredentials() -> ClaudeCredentials? {
        guard let text = runSecurityFindPassword(service: "Claude Code-credentials", account: NSUserName()) else {
            return nil
        }
        guard let creds = try? JSONDecoder().decode(ClaudeCredentials.self, from: Data(text.utf8)) else {
            authLog.error("Keychain item is not in the expected credentials format")
            return nil
        }
        return creds
    }

    private func fetchCodex() async -> ProviderUsage {
        var u = ProviderUsage()
        let path = NSHomeDirectory() + "/.codex/auth.json"

        guard let data = FileManager.default.contents(atPath: path) else {
            u.error = "No auth"
            return u
        }
        guard let creds = try? JSONDecoder().decode(CodexCredentials.self, from: data) else {
            u.error = "Auth format"
            return u
        }

        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        req.setValue("Bearer \(creds.tokens.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(creds.tokens.accountId, forHTTPHeaderField: "Chatgpt-Account-Id")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                u.error = "Network"
                return u
            }
            guard http.statusCode == 200 else {
                u.error = http.statusCode == 429 ? "Rate limit" : "API \(http.statusCode)"
                return u
            }
            let r = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
            // Windows are classified by their actual duration, not their
            // position: the API nowadays reports the weekly limit as
            // primary_window (secondary is null), so primary != 5h.
            let windows = [(r.rateLimit?.primaryWindow, false), (r.rateLimit?.secondaryWindow, true)]
            for (w, positionalWeekly) in windows {
                guard let w else { continue }
                let isWeekly = w.limitWindowSeconds.map { $0 >= 86400 } ?? positionalWeekly
                if isWeekly {
                    u.weeklyPercent = Double(w.usedPercent ?? 0)
                    if let t = w.resetAt { u.weeklyReset = Date(timeIntervalSince1970: Double(t)) }
                } else {
                    u.sessionPercent = Double(w.usedPercent ?? 0)
                    if let t = w.resetAt { u.sessionReset = Date(timeIntervalSince1970: Double(t)) }
                }
            }
            // Named per-model/feature limits (e.g. "GPT-5.3-Codex-Spark")
            for extra in r.additionalRateLimits ?? [] {
                guard let name = extra.limitName, let w = extra.rateLimit?.primaryWindow else { continue }
                let short = name.count > 7 ? String(name.split(separator: "-").last ?? Substring(name)) : name
                u.modelLimits.append(ModelLimit(name: short,
                                                percent: Double(w.usedPercent ?? 0),
                                                reset: w.resetAt.map { Date(timeIntervalSince1970: Double($0)) }))
            }
            u.fetchedAt = Date()
        } catch {
            u.error = "Error"
        }
        return u
    }

    private func fetchGemini() async -> ProviderUsage {
        var auth = await fetchGeminiAccessToken()
        var u = await fetchGeminiUsage(auth: auth)
        // Several Antigravity logins can be present (T3 file, `agy` Keychain).
        // The one that expires last may still be refused with 403, so fall back
        // to the next candidate instead of showing the error.
        while u.error == "API 403", let rejected = auth.token, !geminiRejected.contains(rejected) {
            geminiRejected.insert(rejected)
            authLog.info("Gemini quota API refused a token with 403, trying the next one")
            let next = await fetchGeminiAccessToken()
            guard next.token != nil else { break }
            auth = next
            u = await fetchGeminiUsage(auth: auth)
        }
        // Token revoked or expired early: mint a fresh one once and retry.
        if u.error == "API 401", let rt = auth.refreshToken {
            geminiRefreshed = nil
            let r = await refreshGeminiToken(rt)
            if let fresh = r.token {
                auth.token = fresh
                u = await fetchGeminiUsage(auth: auth)
            } else {
                u.error = r.error ?? u.error
            }
        }
        return u
    }

    private func fetchGeminiUsage(auth: GeminiAuth) async -> ProviderUsage {
        var u = ProviderUsage()
        guard let token = auth.token else {
            u.error = auth.error ?? "No auth"
            return u
        }

        let base = auth.useDailyEndpoint
            ? "https://daily-cloudcode-pa.googleapis.com"
            : "https://cloudcode-pa.googleapis.com"

        // Primary: retrieveUserQuotaSummary returns both 5h and 7d (weekly) buckets
        // plus model-scoped limits (e.g. Gemini 4 Argon). Requires the ACP/CLI
        // User-Agent format or the backend omits native Gemini groups.
        if auth.useDailyEndpoint, let summary = await fetchGeminiQuotaSummary(base: base, token: token) {
            if summary.error == nil || summary.error == "Rate limit" {
                return summary
            }
        }

        // Fallback: retrieveUserQuota (used by free-tier / Gemini CLI accounts).
        var req = makeGeminiRequest(url: "\(base)/v1internal:retrieveUserQuota", token: token)
        req.httpBody = Data("{}".utf8)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                u.error = "Network"
                return u
            }
            guard http.statusCode == 200 else {
                u.error = http.statusCode == 429 ? "Rate limit" : "API \(http.statusCode)"
                return u
            }
            let r = try JSONDecoder().decode(GeminiQuotaResponse.self, from: data)
            let now = Date()
            let weeklyThreshold: TimeInterval = auth.useDailyEndpoint ? 21_600 : 90_000

            var bestSession: (pct: Double, reset: Date?)?
            var bestWeekly: (pct: Double, reset: Date?)?

            for b in r.buckets ?? [] {
                guard let id = b.modelId, id.lowercased().hasPrefix("gemini-") else { continue }
                let reset = b.resetTime.flatMap(parseISO)
                guard b.remainingFraction != nil || reset != nil else { continue }
                // Proto3 JSON omits 0.0; a bucket with resetTime and no remainingFraction is exhausted.
                let remaining = b.remainingFraction ?? 0.0
                let used = min(max((1.0 - remaining) * 100.0, 0), 100)
                let isWeekly = reset.map { $0.timeIntervalSince(now) > weeklyThreshold } ?? false

                if isWeekly {
                    if bestWeekly == nil || used > bestWeekly!.pct ||
                        (used == bestWeekly!.pct && (reset ?? .distantFuture) < (bestWeekly!.reset ?? .distantFuture)) {
                        bestWeekly = (used, reset)
                    }
                } else {
                    if bestSession == nil || used > bestSession!.pct ||
                        (used == bestSession!.pct && (reset ?? .distantFuture) < (bestSession!.reset ?? .distantFuture)) {
                        bestSession = (used, reset)
                    }
                }
            }

            if let s = bestSession {
                u.sessionPercent = s.pct
                u.sessionReset = s.reset
            }
            if let w = bestWeekly {
                u.weeklyPercent = w.pct
                u.weeklyReset = w.reset
            }
            guard u.sessionPercent != nil || u.weeklyPercent != nil else {
                u.error = "No data"
                return u
            }
            u.fetchedAt = now
        } catch {
            u.error = "Error"
        }
        return u
    }

    private func fetchGeminiQuotaSummary(base: String, token: String) async -> ProviderUsage? {
        var req = makeGeminiRequest(url: "\(base)/v1internal:retrieveUserQuotaSummary", token: token)
        req.httpBody = Data("{}".utf8)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return nil }
            if http.statusCode == 429 {
                var u = ProviderUsage()
                u.error = "Rate limit"
                return u
            }
            guard http.statusCode == 200 else { return nil }

            let r = try JSONDecoder().decode(GeminiQuotaSummaryResponse.self, from: data)
            var u = ProviderUsage()
            let now = Date()

            for group in r.groups ?? [] {
                let buckets = group.buckets ?? []
                let groupName = group.displayName ?? ""
                let isGeminiGroup = groupName.localizedCaseInsensitiveContains("gemini")
                    || buckets.contains { ($0.bucketId ?? "").lowercased().hasPrefix("gemini") }
                guard isGeminiGroup else { continue }

                let isPrimaryGroup = buckets.contains {
                    let id = ($0.bucketId ?? "").lowercased()
                    return id == "gemini-5h" || id == "gemini-weekly"
                } || groupName.lowercased() == "gemini models"

                if isPrimaryGroup {
                    for b in buckets {
                        let reset = b.resetTime.flatMap(parseISO)
                        guard b.remainingFraction != nil || reset != nil else { continue }
                        let used = min(max((1.0 - (b.remainingFraction ?? 0.0)) * 100.0, 0), 100)
                        let window = (b.window ?? "").lowercased()
                        let id = (b.bucketId ?? "").lowercased()
                        if window == "weekly" || id.contains("weekly") {
                            u.weeklyPercent = used
                            u.weeklyReset = reset
                        } else if window == "5h" || id.contains("5h") {
                            u.sessionPercent = used
                            u.sessionReset = reset
                        }
                    }
                } else {
                    // Model-scoped Gemini quota group (e.g. "Gemini 4 Argon").
                    let short = groupName.count > 7
                        ? String(groupName.split(separator: " ").last ?? Substring(groupName))
                        : groupName
                    guard !short.isEmpty else { continue }
                    if let b = buckets.first(where: { ($0.window ?? "").lowercased() == "weekly" }) ?? buckets.first {
                        let reset = b.resetTime.flatMap(parseISO)
                        guard b.remainingFraction != nil || reset != nil else { continue }
                        let used = min(max((1.0 - (b.remainingFraction ?? 0.0)) * 100.0, 0), 100)
                        u.modelLimits.append(ModelLimit(name: short, percent: used, reset: reset))
                    }
                }
            }

            guard u.sessionPercent != nil || u.weeklyPercent != nil || !u.modelLimits.isEmpty else {
                return nil
            }
            u.fetchedAt = now
            return u
        } catch {
            return nil
        }
    }

    private func makeGeminiRequest(url: String, token: String) -> URLRequest {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("antigravity/acp/1.5.13", forHTTPHeaderField: "User-Agent")
        return req
    }

    private func fetchGeminiAccessToken() async -> GeminiAuth {
        // Optional override: a dedicated token in a 0600 file.
        let tokenPath = NSHomeDirectory() + "/.config/usagebar/gemini-token"
        if let token = try? String(contentsOfFile: tokenPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            return GeminiAuth(token: token, useDailyEndpoint: true)
        }

        var error = "No auth"
        // Treat tokens that expire within a minute as expired already.
        let cutoff = Date().addingTimeInterval(60)

        // Antigravity credentials: T3 Code's ACP provider token file(s), then
        // Antigravity CLI's (`agy`) login Keychain item.
        var candidates: [AntigravityCredentials.Token] = []
        let t3Base = NSHomeDirectory() + "/.t3/userdata/providers/antigravity"
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: t3Base)) ?? [] {
            let p = "\(t3Base)/\(entry)/antigravity-acp/antigravity-oauth-token"
            guard let data = FileManager.default.contents(atPath: p) else { continue }
            if let creds = try? JSONDecoder().decode(AntigravityCredentials.self, from: data) {
                candidates.append(creds.token)
            } else {
                error = "Auth format"
            }
        }
        if let creds = readAntigravityKeychainCredentials() {
            candidates.append(creds.token)
        }
        candidates.removeAll { geminiRejected.contains($0.accessToken) }
        let expiry: (AntigravityCredentials.Token) -> Date = {
            $0.expiry.flatMap(self.parseISO) ?? .distantFuture
        }
        candidates.sort { expiry($0) > expiry($1) }

        if let best = candidates.first, expiry(best) > cutoff {
            return GeminiAuth(token: best.accessToken, useDailyEndpoint: true, refreshToken: best.refreshToken)
        }
        if !candidates.isEmpty { error = "Auth expired" }

        // All stored access tokens are expired: reuse or mint our own.
        let refreshTokens = candidates.compactMap(\.refreshToken)
        if let r = geminiRefreshed, r.expiry > cutoff, refreshTokens.contains(r.refreshToken),
           !geminiRejected.contains(r.token) {
            return GeminiAuth(token: r.token, useDailyEndpoint: true, refreshToken: r.refreshToken)
        }
        for rt in refreshTokens {
            let r = await refreshGeminiToken(rt)
            if let token = r.token {
                return GeminiAuth(token: token, useDailyEndpoint: true, refreshToken: rt)
            }
            error = r.error ?? error
        }

        // Fallback: Gemini CLI plaintext OAuth credentials.
        let geminiPath = NSHomeDirectory() + "/.gemini/oauth_creds.json"
        if let data = FileManager.default.contents(atPath: geminiPath) {
            if let creds = try? JSONDecoder().decode(GeminiCLICredentials.self, from: data) {
                if !creds.isExpired { return GeminiAuth(token: creds.accessToken, useDailyEndpoint: false) }
                if error == "No auth" { error = "Auth expired" }
            } else if error == "No auth" {
                error = "Auth format"
            }
        }

        return GeminiAuth(token: nil, useDailyEndpoint: true, error: error)
    }

    /// Exchanges Antigravity's refresh token for a new access token.
    ///
    /// Google does not rotate refresh tokens on this grant (verified 2026-11-23:
    /// the response carries no new refresh_token), so T3 and `agy` stay logged
    /// in. The result lives in memory only.
    private func refreshGeminiToken(_ refreshToken: String) async -> (token: String?, error: String?) {
        let clientPath = NSHomeDirectory() + "/.config/usagebar/gemini-oauth-client.json"
        guard let data = FileManager.default.contents(atPath: clientPath),
              let client = try? JSONDecoder().decode(GoogleOAuthClient.self, from: data) else {
            authLog.info("Gemini token expired and no OAuth client config at \(clientPath, privacy: .public)")
            return (nil, "Auth expired")
        }
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "client_id", value: client.clientId),
            URLQueryItem(name: "client_secret", value: client.clientSecret),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
        ]
        // URLComponents leaves "+" unescaped, which form decoding reads as a space.
        let body = (form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        req.httpBody = Data(body.utf8)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                authLog.error("Gemini token refresh failed with HTTP \(status, privacy: .public)")
                // 400 invalid_grant: the login itself is gone; re-login needed.
                return (nil, status == 400 || status == 401 ? "Login expired" : "Refresh \(status)")
            }
            let r = try JSONDecoder().decode(GoogleTokenResponse.self, from: data)
            let expiry = Date().addingTimeInterval(r.expiresIn ?? 3600)
            geminiRefreshed = (r.accessToken, expiry, refreshToken)
            authLog.info("Gemini access token refreshed")
            return (r.accessToken, nil)
        } catch {
            return (nil, "Network")
        }
    }

    /// Reads Antigravity CLI's OAuth credentials from the login Keychain.
    ///
    /// Antigravity CLI uses go-keyring, which calls /usr/bin/security under the
    /// hood, so reading via /usr/bin/security triggers no authorization prompt.
    private func readAntigravityKeychainCredentials() -> AntigravityCredentials? {
        guard var text = runSecurityFindPassword(service: "gemini", account: "antigravity") else {
            return nil
        }
        let prefix = "go-keyring-base64:"
        if text.hasPrefix(prefix) {
            guard let decoded = Data(base64Encoded: String(text.dropFirst(prefix.count))),
                  let decodedStr = String(data: decoded, encoding: .utf8) else {
                authLog.error("Antigravity Keychain item has invalid base64 payload")
                return nil
            }
            text = decodedStr
        }
        guard let creds = try? JSONDecoder().decode(AntigravityCredentials.self, from: Data(text.utf8)) else {
            authLog.error("Antigravity Keychain item is not in the expected credentials format")
            return nil
        }
        return creds
    }

    private func runSecurityFindPassword(service: String, account: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-a", account, "-w", "-s", service]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            authLog.error("could not run /usr/bin/security: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: watchdog)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()

        guard p.terminationStatus == 0 else {
            authLog.info("Keychain lookup for \(service, privacy: .public) exited with status \(p.terminationStatus, privacy: .public)")
            return nil
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? { f.formatOptions = [.withInternetDateTime]; return f.date(from: s) }()
    }
}

// MARK: - Views

struct ProviderRow: View {
    let name: String
    let usage: ProviderUsage
    let now: Date

    var isStale: Bool {
        guard let fetchedAt = usage.fetchedAt else { return false }
        return now.timeIntervalSince(fetchedAt) > usageStalenessThreshold
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(name).font(.system(size: 12, weight: .semibold))
                if isStale, let fetchedAt = usage.fetchedAt {
                    Text(staleLabel(fetchedAt, now: now))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                if let reason = usage.staleReason {
                    Text(reason)
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }
            }

            Group {
                if let e = usage.error {
                    Text(e).font(.system(size: 11)).foregroundColor(.red)
                } else {
                    let w: CGFloat = usage.modelLimits.isEmpty ? 20 : 42
                    if let p = usage.sessionPercent {
                        Row(label: "5h", pct: p, reset: usage.sessionReset, now: now, labelWidth: w)
                    }
                    if let p = usage.weeklyPercent {
                        Row(label: "7d", pct: p, reset: usage.weeklyReset, now: now, labelWidth: w)
                    }
                    ForEach(usage.modelLimits, id: \.name) { m in
                        Row(label: m.name, pct: m.percent, reset: m.reset, now: now, labelWidth: w)
                    }
                }
            }.opacity(isStale ? 0.45 : 1)
        }
    }
}

struct Row: View {
    let label: String
    let pct: Double
    let reset: Date?
    let now: Date
    var labelWidth: CGFloat = 20

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 11)).foregroundColor(.secondary).frame(width: labelWidth, alignment: .leading)

            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: g.size.width * min(pct / 100, 1))
                }
            }
            .frame(height: 5)

            Text(String(format: "%.0f%%", pct))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(color)
                .frame(width: 32, alignment: .trailing)

            if let r = reset {
                Text(remaining(r))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }

    var color: Color { pct >= 80 ? .red : pct >= 60 ? .orange : .green }

    func remaining(_ d: Date) -> String {
        let s = d.timeIntervalSince(now)
        if s <= 0 { return "now" }
        let h = Int(s) / 3600, m = (Int(s) % 3600) / 60
        if h >= 24 { return "\(h/24)d" }
        return h > 0 ? "\(h)h" : "\(m)m"
    }
}

struct ContentView: View {
    @State private var state = AppState()
    @State private var loading = false
    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Usage").font(.system(size: 12, weight: .bold))
                Spacer()
                if loading {
                    ProgressView().scaleEffect(0.5)
                } else {
                    Button(action: { Task { await load() } }) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11))
                    }.buttonStyle(.plain).foregroundColor(.secondary)
                }
            }

            Divider()

            ProviderRow(name: "Claude", usage: state.claude, now: now)
            ProviderRow(name: "Codex", usage: state.codex, now: now).padding(.top, 4)
            ProviderRow(name: "Gemini", usage: state.gemini, now: now).padding(.top, 4)

            Divider()

            HStack {
                if let d = state.lastUpdated {
                    Text(fmt(d)).font(.system(size: 10)).foregroundColor(.secondary)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .font(.system(size: 10)).buttonStyle(.plain).foregroundColor(.secondary)
            }
        }
        .padding(14)
        .task { await autoRefresh() }
    }

    func load() async {
        loading = true
        state = await UsageAPI.shared.fetchAll()
        now = Date()
        loading = false
    }

    func autoRefresh() async {
        await load()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            await load()
        }
    }

    func fmt(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }
}

// MARK: - Panel

class Panel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 280, height: 240),
                   styleMask: [.nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        let v = NSVisualEffectView(frame: contentRect(forFrameRect: frame))
        v.material = .hudWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = 8
        v.layer?.masksToBounds = true
        contentView = v
    }
}

// MARK: - CLI mode (for terminals / cmux Dock)

enum CLI {
    static func color(_ pct: Double) -> String { pct >= 80 ? "\u{1B}[31m" : pct >= 60 ? "\u{1B}[33m" : "\u{1B}[32m" }

    static func bar(_ pct: Double, width: Int = 18) -> String {
        let filled = min(max(Int((pct / 100 * Double(width)).rounded()), 0), width)
        return color(pct) + String(repeating: "█", count: filled)
            + "\u{1B}[0m\u{1B}[2m" + String(repeating: "░", count: width - filled) + "\u{1B}[0m"
    }

    static func remaining(_ d: Date?, now: Date) -> String {
        guard let d else { return "" }
        let s = d.timeIntervalSince(now)
        if s <= 0 { return "now" }
        let h = Int(s) / 3600, m = (Int(s) % 3600) / 60
        if h >= 24 { return "\(h/24)d" }
        return h > 0 ? "\(h)h" : "\(m)m"
    }

    static func row(_ label: String, _ pct: Double, _ reset: Date?, now: Date) -> String {
        let l = label.count > 6 ? String(label.prefix(6)) : label.padding(toLength: 6, withPad: " ", startingAt: 0)
        let p = String(format: "%3.0f%%", pct)
        let r = remaining(reset, now: now)
        return "  \(l) \(bar(pct)) \(color(pct))\(p)\u{1B}[0m \u{1B}[2m\(r)\u{1B}[0m"
    }

    static func section(_ name: String, _ u: ProviderUsage, now: Date) -> String {
        let stale = u.fetchedAt.map { now.timeIntervalSince($0) > usageStalenessThreshold } ?? false
        let asOf: String
        if stale, let fetchedAt = u.fetchedAt {
            asOf = "\u{1B}[2m (\(staleLabel(fetchedAt, now: now)))\u{1B}[0m"
        } else {
            asOf = ""
        }
        let reason = u.staleReason.map { " \u{1B}[33m\($0)\u{1B}[0m" } ?? ""
        var lines = ["\u{1B}[1m\(name)\u{1B}[0m\(asOf)\(reason)"]
        if let e = u.error {
            lines.append("  \u{1B}[31m\(e)\u{1B}[0m")
        } else {
            if let p = u.sessionPercent { lines.append(row("5h", p, u.sessionReset, now: now)) }
            if let p = u.weeklyPercent { lines.append(row("7d", p, u.weeklyReset, now: now)) }
            for m in u.modelLimits { lines.append(row(m.name, m.percent, m.reset, now: now)) }
        }
        return lines.joined(separator: "\n")
    }

    static func run(once: Bool) async {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        if !once {
            // Alternate screen buffer + hidden cursor: redraws replace the
            // frame instead of stacking copies in the scrollback.
            print("\u{1B}[?1049h\u{1B}[?25l", terminator: "")
            for sig in [SIGINT, SIGTERM] {
                signal(sig) { _ in
                    print("\u{1B}[?1049l\u{1B}[?25h", terminator: "")
                    exit(0)
                }
            }
        }
        while true {
            let state = await UsageAPI.shared.fetchAll()
            let now = Date()
            var out = once ? "" : "\u{1B}[H\u{1B}[2J"
            out += "\u{1B}[1mUsage\u{1B}[0m \u{1B}[2m\(f.string(from: now))\u{1B}[0m\n\n"
            out += section("Claude", state.claude, now: now) + "\n\n"
            out += section("Codex", state.codex, now: now) + "\n\n"
            out += section("Gemini", state.gemini, now: now) + "\n"
            print(out, terminator: "")
            fflush(stdout)
            if once { exit(0) }
            try? await Task.sleep(for: .seconds(60))
        }
    }
}

// MARK: - App

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var panel: Panel!
    var hostingView: NSHostingView<ContentView>!
    var globalMonitor: Any?

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)
            b.action = #selector(toggle)
            b.target = self
        }

        panel = Panel()
        hostingView = NSHostingView(rootView: ContentView())
        hostingView.frame = panel.contentView!.bounds
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(hostingView)

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.panel.orderOut(nil)
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        if let m = globalMonitor {
            NSEvent.removeMonitor(m)
            globalMonitor = nil
        }
    }

    @objc func toggle() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            // Fit panel to content
            let fitting = hostingView.fittingSize
            if fitting.width > 0 && fitting.height > 0 {
                panel.setContentSize(fitting)
            }
            if let b = statusItem.button, let w = b.window {
                let r = w.convertToScreen(b.convert(b.bounds, to: nil))
                panel.setFrameOrigin(NSPoint(x: r.midX - panel.frame.width / 2, y: r.minY - panel.frame.height - 2))
            }
            panel.makeKeyAndOrderFront(nil)
        }
    }
}

if CommandLine.arguments.contains("--cli") || CommandLine.arguments.contains("--once") {
    Task.detached { await CLI.run(once: CommandLine.arguments.contains("--once")) }
    dispatchMain()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
