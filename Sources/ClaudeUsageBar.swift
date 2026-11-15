// ClaudeUsageBar — hiển thị mức sử dụng Claude (giới hạn 5 giờ / 7 ngày) trên menu bar macOS.
//
// Nguồn dữ liệu: endpoint OAuth mà Claude Code dùng cho lệnh /usage
//   GET https://api.anthropic.com/api/oauth/usage
// Token được đọc từ Keychain (mục "Claude Code-credentials" do Claude Code tạo khi bạn đăng nhập),
// hoặc từ ~/.claude/.credentials.json, hoặc biến môi trường CLAUDE_CODE_OAUTH_TOKEN.

import AppKit
import Security
import ServiceManagement

// MARK: - Model

struct UsageWindow: Decodable {
    let utilization: Double?
    let resets_at: String?

    var resetDate: Date? { resets_at.flatMap(parseISODate) }
}

struct UsageResponse: Decodable {
    let five_hour: UsageWindow?
    let seven_day: UsageWindow?
    let seven_day_opus: UsageWindow?
    let seven_day_sonnet: UsageWindow?
}

enum UsageError: LocalizedError {
    case noCredentials
    case keychainDenied(Int32)
    case unauthorized
    case sessionInvalid
    case http(Int, String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "Không tìm thấy token Claude Code trong Keychain. Chạy `claude` trong Terminal để đăng nhập, hoặc dùng mục \"Đăng nhập bằng sessionKey claude.ai…\" bên dưới."
        case .keychainDenied(let code):
            return "macOS không cho đọc Keychain (mã \(code)). Bấm Làm mới và chọn \"Always Allow\" khi được hỏi."
        case .unauthorized:
            return "Token Claude Code hết hạn. Mở Terminal và chạy `claude` một lần để làm mới token."
        case .sessionInvalid:
            return "sessionKey claude.ai không hợp lệ hoặc đã hết hạn. Hãy nhập lại."
        case .http(let code, let body):
            return "Lỗi HTTP \(code): \(body.prefix(120))"
        case .decode(let msg):
            return "Không đọc được dữ liệu: \(msg)"
        }
    }
}

// MARK: - Helpers

func parseISODate(_ s: String) -> Date? {
    let f1 = ISO8601DateFormatter()
    f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f1.date(from: s) { return d }
    let f2 = ISO8601DateFormatter()
    f2.formatOptions = [.withInternetDateTime]
    return f2.date(from: s)
}

func formatRemaining(until date: Date?) -> String {
    guard let date else { return "" }
    let secs = Int(date.timeIntervalSinceNow)
    if secs <= 0 { return "sắp reset" }
    let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
    if d > 0 { return "reset sau \(d)n \(h)g" }
    if h > 0 { return "reset sau \(h)g \(m)p" }
    return "reset sau \(m)p"
}

func formatClock(_ date: Date?) -> String {
    guard let date else { return "" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "vi_VN")
    f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE HH:mm"
    return f.string(from: date)
}

func bar(_ pct: Double, width: Int = 20) -> String {
    let filled = max(0, min(width, Int((pct / 100 * Double(width)).rounded())))
    return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
}

func color(for pct: Double) -> NSColor {
    if pct >= 90 { return .systemRed }
    if pct >= 70 { return .systemOrange }
    return .labelColor
}

// MARK: - Credentials

enum Credentials {
    /// Token OAuth của Claude Code.
    static func claudeCodeToken() throws -> String {
        if let t = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"], !t.isEmpty {
            return t
        }

        var deniedCode: Int32?
        for service in claudeCodeKeychainServices() {
            let (status, data) = runSecurity(["find-generic-password", "-s", service, "-w"])
            if status == 0, let data, let t = extractToken(data) { return t }
            if status != 0 && status != 44 { deniedCode = status } // 44 = không có mục này
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        var dirs = [home.appendingPathComponent(".claude"), home.appendingPathComponent(".config/claude")]
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            dirs.insert(URL(fileURLWithPath: custom), at: 0)
        }
        for dir in dirs {
            if let data = try? Data(contentsOf: dir.appendingPathComponent(".credentials.json")),
               let t = extractToken(data) { return t }
        }

        if let code = deniedCode { throw UsageError.keychainDenied(code) }
        throw UsageError.noCredentials
    }

    /// Liệt kê các mục Keychain có tên bắt đầu bằng "Claude Code-credentials"
    /// (Claude Code có thể thêm hậu tố khi dùng CLAUDE_CONFIG_DIR). Chỉ đọc thuộc tính nên không hỏi quyền.
    private static func claudeCodeKeychainServices() -> [String] {
        var result = ["Claude Code-credentials"]
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var items: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
           let list = items as? [[String: Any]] {
            for item in list {
                if let svc = item[kSecAttrService as String] as? String,
                   svc.hasPrefix("Claude Code-credentials"), !result.contains(svc) {
                    result.append(svc)
                }
            }
        }
        return result
    }

    /// Dùng /usr/bin/security để đọc Keychain: macOS chỉ hỏi quyền 1 lần ("Always Allow")
    /// và quyền đó không bị mất khi build lại app.
    private static func runSecurity(_ args: [String]) -> (Int32, Data?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return (-1, nil) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data.isEmpty ? nil : data)
    }

    private static func extractToken(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let oauth = (obj["claudeAiOauth"] as? [String: Any]) ?? obj
        if let token = oauth["accessToken"] as? String, !token.isEmpty { return token }
        return nil
    }

    // MARK: sessionKey claude.ai (lưu trong Keychain của chính app)

    private static let ownService = "ClaudeUsageBar"
    private static let ownAccount = "claude.ai-sessionKey"

    static var sessionKey: String? {
        get {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: ownService,
                kSecAttrAccount as String: ownAccount,
                kSecReturnData as String: true,
            ]
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
                  let data = out as? Data, let s = String(data: data, encoding: .utf8), !s.isEmpty
            else { return nil }
            return s
        }
        set {
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: ownService,
                kSecAttrAccount as String: ownAccount,
            ]
            SecItemDelete(base as CFDictionary)
            guard let v = newValue, !v.isEmpty else { return }
            var add = base
            add[kSecValueData as String] = Data(v.utf8)
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

// MARK: - API

enum UsageAPI {
    static func fetch() async throws -> UsageResponse {
        // Ưu tiên sessionKey nếu người dùng đã nhập, sau đó tới token Claude Code.
        if let key = Credentials.sessionKey {
            return try await fetchWeb(sessionKey: key)
        }
        return try await fetchOAuth(token: try Credentials.claudeCodeToken())
    }

    private static func fetchOAuth(token: String) async throws -> UsageResponse {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("claude-usage-bar/1.0", forHTTPHeaderField: "User-Agent")
        let data = try await send(req, authError: .unauthorized)
        return try decode(data)
    }

    private static func webRequest(_ url: String, _ key: String) -> URLRequest {
        var req = URLRequest(url: URL(string: url)!)
        req.timeoutInterval = 20
        req.httpShouldHandleCookies = false
        req.setValue("sessionKey=\(key)", forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("https://claude.ai/settings/usage", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        return req
    }

    private static func fetchWeb(sessionKey key: String) async throws -> UsageResponse {
        let defaults = UserDefaults.standard
        var org = defaults.string(forKey: "orgId")
        if org == nil {
            let data = try await send(webRequest("https://claude.ai/api/organizations", key), authError: .sessionInvalid)
            guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw UsageError.decode("danh sách organization")
            }
            // Ưu tiên tổ chức có quyền chat (tài khoản Pro/Max cá nhân).
            let chosen = list.first { ($0["capabilities"] as? [String])?.contains("chat") == true } ?? list.first
            org = chosen?["uuid"] as? String
            guard let org else { throw UsageError.decode("không tìm thấy organization") }
            defaults.set(org, forKey: "orgId")
        }
        do {
            let data = try await send(webRequest("https://claude.ai/api/organizations/\(org!)/usage", key),
                                      authError: .sessionInvalid)
            return try decode(data)
        } catch {
            defaults.removeObject(forKey: "orgId") // lần sau tìm lại org
            throw error
        }
    }

    private static func send(_ req: URLRequest, authError: UsageError) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw authError }
        guard (200..<300).contains(code) else {
            throw UsageError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private static func decode(_ data: Data) throws -> UsageResponse {
        do { return try JSONDecoder().decode(UsageResponse.self, from: data) }
        catch { throw UsageError.decode(error.localizedDescription) }
    }
}

// MARK: - App

enum DisplayMode: String, CaseIterable {
    case both, fiveHour, sevenDay, iconOnly
    var title: String {
        switch self {
        case .both: return "5 giờ + 7 ngày"
        case .fiveHour: return "Chỉ 5 giờ"
        case .sevenDay: return "Chỉ 7 ngày"
        case .iconOnly: return "Chỉ biểu tượng"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var timer: Timer?
    private var usage: UsageResponse?
    private var lastError: String?
    private var lastUpdate: Date?
    private var loading = false

    private let refreshInterval: TimeInterval = 300 // 5 phút

    private var displayMode: DisplayMode {
        get { DisplayMode(rawValue: UserDefaults.standard.string(forKey: "displayMode") ?? "") ?? .both }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "displayMode"); updateTitle() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateTitle()
        rebuildMenu()

        refresh()
        timer = Timer.scheduledTimer(timeInterval: refreshInterval, target: self,
                                     selector: #selector(refresh), userInfo: nil, repeats: true)
        // Cập nhật lại phần "reset sau …" mỗi phút mà không cần gọi API.
        Timer.scheduledTimer(timeInterval: 60, target: self,
                             selector: #selector(tick), userInfo: nil, repeats: true)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func didWake() {
        perform(#selector(refresh), with: nil, afterDelay: 5)
    }

    @objc private func tick() {
        updateTitle()
    }

    // MARK: Refresh

    @objc func refresh() {
        guard !loading else { return }
        loading = true
        Task { @MainActor [weak self] in
            do {
                let u = try await UsageAPI.fetch()
                self?.usage = u
                self?.lastError = nil
                self?.lastUpdate = Date()
            } catch {
                self?.lastError = error.localizedDescription
            }
            self?.loading = false
            self?.updateTitle()
            self?.rebuildMenu()
        }
    }

    // MARK: Status bar title

    private func updateTitle() {
        guard let button = statusItem?.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium)
        let result = NSMutableAttributedString()

        func append(_ s: String, _ c: NSColor = .labelColor) {
            result.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: c]))
        }

        if let img = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Claude") {
            img.isTemplate = true
            button.image = img
            button.imagePosition = .imageLeading
        } else {
            append("✳︎ ")
        }

        let five = usage?.five_hour?.utilization
        let seven = usage?.seven_day?.utilization

        switch displayMode {
        case .iconOnly:
            break
        case .fiveHour:
            if let five { append(" \(Int(five.rounded()))%", color(for: five)) } else { append(" –") }
        case .sevenDay:
            if let seven { append(" \(Int(seven.rounded()))%", color(for: seven)) } else { append(" –") }
        case .both:
            if let five { append(" \(Int(five.rounded()))%", color(for: five)) } else { append(" –") }
            append(" · ", .secondaryLabelColor)
            if let seven { append("\(Int(seven.rounded()))%", color(for: seven)) } else { append("–") }
        }

        if usage == nil && lastError != nil && displayMode != .iconOnly {
            result.setAttributedString(NSAttributedString(
                string: " !", attributes: [.font: font, .foregroundColor: NSColor.systemRed]))
        }

        button.attributedTitle = result
        button.toolTip = tooltip()
    }

    private func tooltip() -> String {
        var lines: [String] = []
        if let w = usage?.five_hour, let p = w.utilization {
            lines.append("5 giờ: \(Int(p.rounded()))% · \(formatRemaining(until: w.resetDate))")
        }
        if let w = usage?.seven_day, let p = w.utilization {
            lines.append("7 ngày: \(Int(p.rounded()))% · \(formatRemaining(until: w.resetDate))")
        }
        if let e = lastError { lines.append("⚠︎ \(e)") }
        return lines.isEmpty ? "Claude Usage" : lines.joined(separator: "\n")
    }

    // MARK: Menu

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
        // Dữ liệu cũ hơn 1 phút thì làm mới luôn khi mở menu.
        if let last = lastUpdate, Date().timeIntervalSince(last) < 60 { return }
        refresh()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let header = NSMenuItem(title: "Claude Usage", action: nil, keyEquivalent: "")
        header.attributedTitle = NSAttributedString(
            string: "Claude Usage", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if let u = usage {
            addWindow("Phiên hiện tại (5 giờ)", u.five_hour)
            addWindow("Tuần (7 ngày, mọi model)", u.seven_day)
            if let w = u.seven_day_opus, w.utilization != nil { addWindow("Tuần – Opus", w) }
            if let w = u.seven_day_sonnet, w.utilization != nil { addWindow("Tuần – Sonnet", w) }
        } else if !loading && lastError == nil {
            menu.addItem(disabled("Đang tải…"))
        }

        if let e = lastError {
            let item = disabled("⚠︎ \(e)")
            item.attributedTitle = NSAttributedString(
                string: "⚠︎ \(e)",
                attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.menuFont(ofSize: 12)])
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let status = loading ? "Đang cập nhật…"
            : lastUpdate.map { "Cập nhật lúc \(formatClock($0))" } ?? "Chưa cập nhật"
        menu.addItem(disabled(status))

        let refreshItem = NSMenuItem(title: "Làm mới", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let displayItem = NSMenuItem(title: "Hiển thị trên thanh menu", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for mode in DisplayMode.allCases {
            let i = NSMenuItem(title: mode.title, action: #selector(chooseMode(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = mode.rawValue
            i.state = mode == displayMode ? .on : .off
            sub.addItem(i)
        }
        displayItem.submenu = sub
        menu.addItem(displayItem)

        let web = NSMenuItem(title: "Mở trang usage trên claude.ai", action: #selector(openWeb), keyEquivalent: "")
        web.target = self
        menu.addItem(web)

        if Credentials.sessionKey == nil {
            let sk = NSMenuItem(title: "Đăng nhập bằng sessionKey claude.ai…", action: #selector(enterSessionKey), keyEquivalent: "")
            sk.target = self
            menu.addItem(sk)
        } else {
            let sk = NSMenuItem(title: "Xoá sessionKey (dùng lại token Claude Code)", action: #selector(clearSessionKey), keyEquivalent: "")
            sk.target = self
            menu.addItem(sk)
        }

        let login = NSMenuItem(title: "Khởi động cùng macOS", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Thoát", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func addWindow(_ title: String, _ w: UsageWindow?) {
        guard let w, let pct = w.utilization else { return }
        let mono = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let s = NSMutableAttributedString(
            string: "\(title)\n", attributes: [.font: NSFont.menuFont(ofSize: 13)])
        s.append(NSAttributedString(
            string: "\(bar(pct))  \(Int(pct.rounded()))%\n",
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                         .foregroundColor: pct >= 70 ? color(for: pct) : NSColor.controlAccentColor]))
        var resetText = formatRemaining(until: w.resetDate)
        if let d = w.resetDate { resetText += " (\(formatClock(d)))" }
        s.append(NSAttributedString(
            string: resetText, attributes: [.font: mono, .foregroundColor: NSColor.secondaryLabelColor]))

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = s
        item.isEnabled = false
        menu.addItem(item)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    @objc private func chooseMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let m = DisplayMode(rawValue: raw) {
            displayMode = m
        }
    }

    @objc private func openWeb() {
        NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
    }

    @objc private func enterSessionKey() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Nhập sessionKey của claude.ai"
        alert.informativeText = """
        Dùng khi bạn không cài Claude Code.
        1. Mở claude.ai trên trình duyệt (đã đăng nhập).
        2. Mở Developer Tools (⌥⌘I) → tab Application/Storage → Cookies → https://claude.ai.
        3. Copy giá trị cookie "sessionKey" (bắt đầu bằng sk-ant-sid…) và dán vào đây.
        Key được lưu trong Keychain của máy bạn và chỉ gửi tới claude.ai.
        """
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-ant-sid01-…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Lưu")
        alert.addButton(withTitle: "Huỷ")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.hasPrefix("sessionKey=") { key.removeFirst("sessionKey=".count) }
        guard !key.isEmpty else { return }
        Credentials.sessionKey = key
        UserDefaults.standard.removeObject(forKey: "orgId")
        usage = nil
        lastError = nil
        refresh()
    }

    @objc private func clearSessionKey() {
        Credentials.sessionKey = nil
        UserDefaults.standard.removeObject(forKey: "orgId")
        usage = nil
        lastError = nil
        refresh()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Không bật được khởi động cùng macOS"
            alert.informativeText = "\(error.localizedDescription)\nHãy chắc chắn app nằm trong /Applications."
            alert.runModal()
        }
    }
}

// MARK: - Entry point

@main
struct ClaudeUsageBarMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
