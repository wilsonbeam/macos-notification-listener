import Foundation
import ArgumentParser
import ApplicationServices
import Cocoa

// MARK: - Notification Model

struct CapturedNotification: Codable {
    let timestamp: String
    let app: String
    let bundleId: String
    let title: String
    let body: String
    let identifier: String
}

// MARK: - Log Stream Parser

class LogStreamParser {
    var handler: ((CapturedNotification) -> Void)?
    private var process: Process?

    // Regex patterns for extracting notification info
    // Delivering <NotificationRecord app:"com.example.app" ident:"id123" ...>
    private let deliveringPattern = try! NSRegularExpression(
        pattern: #"(?:Delivering|Presenting)\s+<NotificationRecord\s+app:"([^"]+)"\s+ident:"([^"]*)"#
    )
    // Connection <bundleId> with path:
    private let connectionPattern = try! NSRegularExpression(
        pattern: #"Connection\s+(\S+)\s+with\s+path:"#
    )
    // DND resolution with bundleIdentifier:
    private let dndPattern = try! NSRegularExpression(
        pattern: #"bundleIdentifier:\s*(\S+)"#
    )
    // title/body from NotificationRecord format: title:"..." or title:<hash>
    private let titlePattern = try! NSRegularExpression(
        pattern: #"title:(?:"([^"]*)"|\{length\s*=\s*\d+\})"#
    )
    private let bodyPattern = try! NSRegularExpression(
        pattern: #"body:(?:"([^"]*)"|\{length\s*=\s*\d+\})"#
    )
    // "processed by pipeline, scheduled for delivery" pattern
    private let pipelinePattern = try! NSRegularExpression(
        pattern: #"processed by pipeline.*scheduled for delivery"#
    )

    func start() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        proc.arguments = [
            "stream",
            "--predicate", #"process == "usernoted" OR process == "NotificationCenter""#,
            "--style", "ndjson"
        ]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                for line in text.components(separatedBy: "\n") where !line.isEmpty {
                    self?.parseLine(line)
                }
            }
        }

        do {
            try proc.run()
            self.process = proc
            fputs("log stream started (pid \(proc.processIdentifier))\n", stderr)
        } catch {
            fputs("Failed to start log stream: \(error)\n", stderr)
        }
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    private func parseLine(_ line: String) {
        // Try to parse as JSON first
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventMessage = json["eventMessage"] as? String else {
            return
        }

        let timestamp = (json["timestamp"] as? String) ?? ISO8601DateFormatter().string(from: Date())

        // Check for Delivering/Presenting NotificationRecord
        let nsMessage = eventMessage as NSString
        let range = NSRange(location: 0, length: nsMessage.length)

        if let match = deliveringPattern.firstMatch(in: eventMessage, range: range) {
            let bundleId = nsMessage.substring(with: match.range(at: 1))
            let ident = nsMessage.substring(with: match.range(at: 2))

            // Try to extract title/body
            let title = extractCapture(titlePattern, in: eventMessage) ?? ""
            let body = extractCapture(bodyPattern, in: eventMessage) ?? ""

            let appName = bundleId.components(separatedBy: ".").last ?? bundleId

            let notif = CapturedNotification(
                timestamp: timestamp,
                app: appName,
                bundleId: bundleId,
                title: title,
                body: body,
                identifier: ident
            )
            handler?(notif)
            return
        }

        // Check for pipeline delivery pattern
        if pipelinePattern.firstMatch(in: eventMessage, range: range) != nil {
            // Try to find bundleId from the message
            if let bundleMatch = dndPattern.firstMatch(in: eventMessage, range: range) {
                let bundleId = nsMessage.substring(with: bundleMatch.range(at: 1))
                let appName = bundleId.components(separatedBy: ".").last ?? bundleId
                let notif = CapturedNotification(
                    timestamp: timestamp,
                    app: appName,
                    bundleId: bundleId,
                    title: "",
                    body: "",
                    identifier: ""
                )
                handler?(notif)
            }
            return
        }
    }

    private func extractCapture(_ regex: NSRegularExpression, in text: String) -> String? {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        // Try group 1 (quoted value)
        if match.range(at: 1).location != NSNotFound {
            return ns.substring(with: match.range(at: 1))
        }
        return nil
    }
}

// MARK: - Accessibility Reader

struct AccessibilityNotificationInfo {
    let appName: String
    let title: String
    let body: String
}

class AccessibilityReader {
    /// Find the NotificationCenter process and read notification banner content
    static func readNotificationBanner() -> AccessibilityNotificationInfo? {
        guard let ncApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.notificationcenterui"
        }) else {
            fputs("[ax] NotificationCenter process not found\n", stderr)
            return nil
        }

        let axApp = AXUIElementCreateApplication(ncApp.processIdentifier)

        var windowsRef: CFTypeRef?
        let winResult = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
        guard winResult == .success, let windows = windowsRef as? [AXUIElement] else {
            return nil
        }

        for window in windows {
            // Check window title
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)

            // Traverse into the window looking for notification groups
            if let info = traverseForNotification(window) {
                return info
            }
        }
        return nil
    }

    /// Poll for notification banner for up to 2 seconds
    static func pollForNotification() -> AccessibilityNotificationInfo? {
        for _ in 0..<20 {
            if let info = readNotificationBanner() {
                return info
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    private static func traverseForNotification(_ element: AXUIElement) -> AccessibilityNotificationInfo? {
        // Check if this element has a description that looks like "AppName, Title, Body"
        var descRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descRef)

        if let desc = descRef as? String, !desc.isEmpty {
            // Check if it has AXStaticText children (indicates notification group)
            let texts = getChildStaticTexts(element)
            if texts.count >= 2 {
                // Parse description: "AppName, Title, Body"
                let parts = desc.components(separatedBy: ", ")
                let appName = parts.count > 0 ? parts[0] : ""
                // Use child static text values for title/body (more reliable)
                let title = texts.count > 0 ? texts[0] : (parts.count > 1 ? parts[1] : "")
                let body = texts.count > 1 ? texts[1] : (parts.count > 2 ? parts[2...].joined(separator: ", ") : "")

                if !title.isEmpty || !body.isEmpty {
                    return AccessibilityNotificationInfo(appName: appName, title: title, body: body)
                }
            } else if desc.contains(", ") {
                // Fallback: parse from description alone
                let parts = desc.components(separatedBy: ", ")
                if parts.count >= 2 {
                    let appName = parts[0]
                    let title = parts.count > 1 ? parts[1] : ""
                    let body = parts.count > 2 ? parts[2...].joined(separator: ", ") : ""
                    return AccessibilityNotificationInfo(appName: appName, title: title, body: body)
                }
            }
        }

        // Recurse into children
        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return nil }

        for child in children {
            if let info = traverseForNotification(child) {
                return info
            }
        }
        return nil
    }

    private static func getChildStaticTexts(_ element: AXUIElement) -> [String] {
        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return [] }

        var texts: [String] = []
        for child in children {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            if let role = roleRef as? String, role == "AXStaticText" {
                var valueRef: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &valueRef)
                if let value = valueRef as? String {
                    texts.append(value)
                }
            }
        }
        return texts
    }
}

// MARK: - Output Manager

class OutputManager {
    let webhookURL: URL?
    let outputFile: String?
    let useStdout: Bool
    private let encoder = JSONEncoder()
    private let session = URLSession.shared

    init(webhookURL: URL?, outputFile: String?, useStdout: Bool) {
        self.webhookURL = webhookURL
        self.outputFile = outputFile
        self.useStdout = useStdout
        encoder.outputFormatting = [.sortedKeys]

        if let outputFile = outputFile {
            let dir = (outputFile as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }

    func emit(_ notification: CapturedNotification) {
        guard let jsonData = try? encoder.encode(notification),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }

        if useStdout {
            print(jsonString)
            fflush(stdout)
        }

        if let outputFile = outputFile {
            let line = jsonString + "\n"
            if let handle = FileHandle(forWritingAtPath: outputFile) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                handle.closeFile()
            } else {
                FileManager.default.createFile(atPath: outputFile, contents: line.data(using: .utf8))
            }
        }

        if let url = webhookURL, let jsonData = try? encoder.encode(notification) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonData
            session.dataTask(with: request).resume()
        }
    }
}

// MARK: - CLI

@main
struct NotificationListener: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notification-listener",
        abstract: "Capture macOS notifications via log stream and output as JSON lines."
    )

    @Flag(name: .long, help: "Run as background daemon")
    var daemon = false

    @Option(name: .long, help: "Webhook URL to POST notifications to")
    var webhook: String?

    @Option(name: .long, help: "Output file path (default: ~/.notification-listener/notifications.jsonl)")
    var output: String?

    @Flag(name: .long, help: "Stream JSON lines to stdout")
    var stdout = false

    @Option(name: .long, help: "Filter by app bundle ID or name (comma-separated)")
    var filterApps: String?

    func run() throws {
        let effectiveOutput = output ?? "\(FileManager.default.homeDirectoryForCurrentUser.path)/.notification-listener/notifications.jsonl"
        let webhookURL = webhook.flatMap { URL(string: $0) }
        let useStdout = self.stdout || !self.daemon

        let outputManager = OutputManager(
            webhookURL: webhookURL,
            outputFile: effectiveOutput,
            useStdout: useStdout
        )

        let appFilter: Set<String>? = filterApps.map {
            Set($0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces).lowercased() })
        }

        fputs("notification-listener starting (log stream mode)...\n", stderr)
        fputs("Output file: \(effectiveOutput)\n", stderr)
        if let url = webhookURL { fputs("Webhook: \(url)\n", stderr) }
        fputs("Stdout: \(useStdout)\n", stderr)

        let parser = LogStreamParser()
        parser.handler = { notif in
            if let filter = appFilter {
                guard filter.contains(notif.app.lowercased()) || filter.contains(notif.bundleId.lowercased()) else { return }
            }

            // Try to enrich with Accessibility API data
            var enriched = notif
            DispatchQueue.global(qos: .userInitiated).async {
                if let axInfo = AccessibilityReader.pollForNotification() {
                    fputs("[ax] Got notification content: \(axInfo.appName) - \(axInfo.title): \(axInfo.body)\n", stderr)
                    enriched = CapturedNotification(
                        timestamp: notif.timestamp,
                        app: axInfo.appName.isEmpty ? notif.app : axInfo.appName,
                        bundleId: notif.bundleId,
                        title: axInfo.title.isEmpty ? notif.title : axInfo.title,
                        body: axInfo.body.isEmpty ? notif.body : axInfo.body,
                        identifier: notif.identifier
                    )
                } else {
                    fputs("[ax] Could not read notification banner via Accessibility API\n", stderr)
                }
                outputManager.emit(enriched)
            }
        }
        parser.start()

        signal(SIGINT) { _ in
            fputs("\nShutting down...\n", stderr)
            Darwin.exit(0)
        }
        signal(SIGTERM) { _ in
            fputs("\nShutting down...\n", stderr)
            Darwin.exit(0)
        }

        RunLoop.main.run()
    }
}
