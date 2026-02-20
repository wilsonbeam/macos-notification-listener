# macos-notification-listener

## Goal
A lightweight macOS daemon/CLI that captures all incoming user notifications and makes them available for automation.

## Requirements

### Core
- Swift-based CLI tool (no Xcode project needed, just Swift Package Manager)
- Listens to ALL macOS notifications (from any app) using the macOS Notification Center APIs
- Captures: app name/bundle ID, title, subtitle, body, timestamp, category
- Runs as a background daemon

### Output Methods (implement all)
1. **JSON Lines file** — append each notification as a JSON line to `~/.notification-listener/notifications.jsonl`
2. **Webhook** — POST JSON to a configurable URL (e.g., `http://localhost:8080/notification`)
3. **stdout** — stream JSON lines to stdout when running in foreground mode

### CLI Interface
```
notification-listener [--daemon] [--webhook URL] [--output FILE] [--stdout]
```

### Notification Format
```json
{
  "timestamp": "2026-02-20T11:00:00+09:00",
  "app": "Telegram",
  "bundleId": "org.telegram.TelegramDesktop",
  "title": "Wanseob",
  "body": "hey wilson",
  "category": "message"
}
```

### Technical Notes
- Use `NSDistributedNotificationCenter` or `CGEvent` taps or the SQLite approach
- May need Accessibility permissions
- Consider using `NSWorkspace.didReceiveNotification` or similar APIs
- Look into private APIs if public ones are insufficient (e.g., `UserNotifications` framework)
- **Important**: Research the best approach for capturing OTHER apps' notifications (not just self-posted ones). Options include:
  - Reading the notification center SQLite DB (`darwin/notificationcenter`)
  - Using `CGEventTap` to intercept
  - Using the `DistributedNotificationCenter`
  - macOS Notification Center XPC service
  - Accessibility API approach

### Build
- Swift Package Manager (`swift build`)
- Should compile on macOS 13+ (Ventura and later)
- Produce a single binary

### Nice to Have
- Launchd plist for auto-start
- Filter by app name / bundle ID
- Rate limiting / dedup
