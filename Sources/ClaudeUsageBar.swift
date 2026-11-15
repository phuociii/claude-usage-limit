// ClaudeUsageBar — hiển thị mức sử dụng Claude (giới hạn 5 giờ / 7 ngày) trên menu bar macOS.
//
// Nguồn dữ liệu: endpoint OAuth mà Claude Code dùng cho lệnh /usage
//   GET https://api.anthropic.com/api/oauth/usage
// Token được đọc từ Keychain (mục "Claude Code-credentials" do Claude Code tạo khi bạn đăng nhập),
// hoặc từ ~/.claude/.credentials.json, hoặc biến môi trường CLAUDE_CODE_OAUTH_TOKEN.

import AppKit
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
    case unauthorized
    case http(Int, String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "Không tìm thấy token Claude Code. Hãy cài Claude Code và chạy `claude` để đăng nhập."
        case .unauthorized:
            return "Token hết hạn. Mở Terminal và chạy `claude` một lần để làm mới token."
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
    static func accessToken() throws -> String {
        if let t = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"], !t.isEmpty {
            return t
        }
        if let json = keychainJSON(), let t = extractToken(json) { return t }

        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file), let t = extractToken(data) { return t }

        throw UsageError.noCredentials
    }

    /// Dùng /usr/bin/security để đọc Keychain: macOS chỉ hỏi quyền 1 lần ("Always Allow")
    /// và quyền đó không bị mất khi build lại app.
    private static func keychainJSON() -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }

    private static func extractToken(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        return token
    }
}

// MARK: - API

enum UsageAPI {
    static func fetch() async throws -> UsageResponse {
        let token = try Credentials.accessToken()
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("claude-usage-bar/1.0", forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw UsageError.unauthorized }
        guard (200..<300).contains(code) else {
            throw UsageError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
            throw UsageError.decode(error.localizedDescription)
        }
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
