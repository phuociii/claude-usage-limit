# Claude Usage Bar

Hiển thị mức sử dụng Claude (giới hạn **phiên 5 giờ** và **tuần 7 ngày**) ngay trên thanh menu bar của MacBook.

```
✳ 23% · 41%        ← 5 giờ · 7 ngày (chuyển cam ≥70%, đỏ ≥90%)
```

Bấm vào để xem chi tiết: thanh tiến độ, thời gian còn lại đến lúc reset, riêng Opus/Sonnet (nếu có).

## Cách hoạt động

App đọc token đăng nhập mà **Claude Code** đã lưu trong Keychain (`Claude Code-credentials`)
rồi gọi endpoint `https://api.anthropic.com/api/oauth/usage`, chính là nguồn dữ liệu của lệnh `/usage`
trong Claude Code. Số liệu khớp với trang claude.ai → Settings → Usage (Pro/Max).

**Yêu cầu:** đã cài [Claude Code](https://docs.claude.com/claude-code) và đăng nhập bằng tài khoản Claude (`claude` → `/login`).

> Lần đầu chạy, macOS sẽ hỏi cho phép `security` đọc Keychain → chọn **Always Allow**.

Có 2 cách dùng, chọn một:

---

## Cách 0: Tải app build sẵn (không cần Xcode / Command Line Tools)

1. Vào tab **Actions** của repo → chọn lần chạy **Build macOS app** mới nhất → tải **ClaudeUsageBar** ở mục *Artifacts*.
2. Giải nén (có thể phải giải nén 2 lần) → kéo `ClaudeUsageBar.app` vào **Applications**.
3. App chưa được Apple ký nên cần gỡ cờ cách ly một lần:

```bash
xattr -dr com.apple.quarantine /Applications/ClaudeUsageBar.app
```

```bash
open /Applications/ClaudeUsageBar.app
```

## Cách 1: App native (Swift, không cần cài gì thêm)

Yêu cầu macOS 13+ và Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone <repo-này> && cd claude-usage-limit
```

```bash
./build.sh --install
```

Lệnh trên build `ClaudeUsageBar.app`, copy vào `/Applications` và mở luôn.
Trong menu có:

- **Làm mới** (⌘R): tự động làm mới mỗi 5 phút, khi mở menu và khi máy thức dậy
- **Hiển thị trên thanh menu**: `5 giờ + 7 ngày` / `Chỉ 5 giờ` / `Chỉ 7 ngày` / `Chỉ biểu tượng`
- **Khởi động cùng macOS**
- **Mở trang usage trên claude.ai**

Gỡ cài đặt: Thoát app, xoá `/Applications/ClaudeUsageBar.app`.

## Cách 2: Plugin SwiftBar / xbar (một file bash)

1. Cài [SwiftBar](https://github.com/swiftbar/SwiftBar): `brew install --cask swiftbar`
2. Copy plugin vào thư mục plugin của SwiftBar:

```bash
cp swiftbar/claude-usage.5m.sh ~/Library/Application\ Support/SwiftBar/Plugins/
```

(Đổi `5m` trong tên file thành `1m`, `10m`… để đổi tần suất cập nhật.)

## Xử lý lỗi

| Biểu hiện | Cách sửa |
|---|---|
| `!` / "Token hết hạn" | Mở Terminal, chạy `claude` một lần (Claude Code tự làm mới token), rồi bấm **Làm mới** |
| "Không tìm thấy token" | Cài Claude Code và đăng nhập. (Hoặc đặt biến môi trường `CLAUDE_CODE_OAUTH_TOKEN` chứa access token) |
| Không có số tuần Opus/Sonnet | Bình thường: API chỉ trả về khi gói của bạn có giới hạn riêng |

> Lưu ý: `api/oauth/usage` là endpoint nội bộ Claude Code dùng, không phải API công khai, nên có thể thay đổi trong tương lai.
