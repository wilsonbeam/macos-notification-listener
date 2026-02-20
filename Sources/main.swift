import Foundation
import ArgumentParser
import SQLite3

// MARK: - Notification Model

struct CapturedNotification: Codable {
    let timestamp: String
    let app: String
    let bundleId: String
    let title: String
    let body: String
    let category: String
}

// MARK: - SQLite DB Poller

class NotificationDBPoller {
    private var lastRowId: Int64 = 0
    private let dbPath: String?

    init() {
        dbPath = Self.findNotificationDB()
        if let path = dbPath {
            fputs("Using notification DB: \(path)\n", stderr)
            lastRowId = getMaxRowId() ?? 0
        } else {
            fputs("Warning: Could not find notification center database\n", stderr)
        }
    }

    static func findNotificationDB() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // macOS stores notification DB in DarwinNotificationCenter or the delivered notifications DB
        // On macOS Ventura+, delivered notifications are in a per-user db
        let userNotifDir = "\(home)/Library/Group Containers/group.com.apple.usernotes"
        if FileManager.default.fileExists(atPath: userNotifDir) {
            let enumerator = FileManager.default.enumerator(atPath: userNotifDir)
            while let file = enumerator?.nextObject() as? String {
                if file.hasSuffix(".db") || file.hasSuffix(".sqlite") {
                    return "\(userNotifDir)/\(file)"
                }
            }
        }

        // Try macOS Notification Center delivered notifications DB
        // This is typically at ~/Library/Application Support/NotificationCenter/<uuid>.db  (older macOS)
        let ncDir = "\(home)/Library/Application Support/NotificationCenter"
        if FileManager.default.fileExists(atPath: ncDir) {
            let enumerator = FileManager.default.enumerator(atPath: ncDir)
            while let file = enumerator?.nextObject() as? String {
                if file.hasSuffix(".db") || file.hasSuffix(".sqlite") {
                    return "\(ncDir)/\(file)"
                }
            }
        }

        return nil
    }

    func getMaxRowId() -> Int64? {
        guard let dbPath = dbPath else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        // Try common table names
        let queries = [
            "SELECT MAX(rowid) FROM record",
            "SELECT MAX(rowid) FROM delivered",
            "SELECT MAX(rowid) FROM notifications",
        ]

        for query in queries {
            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    let val = sqlite3_column_int64(stmt, 0)
                    sqlite3_finalize(stmt)
                    return val
                }
                sqlite3_finalize(stmt)
            }
        }
        return nil
    }

    func pollNewNotifications() -> [CapturedNotification] {
        guard let dbPath = dbPath else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_close(db) }

        var results: [CapturedNotification] = []
        var stmt: OpaquePointer?

        // Try to query with common schemas
        let query = "SELECT rowid, * FROM record WHERE rowid > ? ORDER BY rowid ASC"
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, lastRowId)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let rowid = sqlite3_column_int64(stmt, 0)
                if rowid > lastRowId { lastRowId = rowid }
                // Extract columns - schema varies by macOS version
                let colCount = sqlite3_column_count(stmt)
                var data: [String: String] = [:]
                for i in 0..<colCount {
                    if let name = sqlite3_column_name(stmt, i),
                       let val = sqlite3_column_text(stmt, i) {
                        data[String(cString: name)] = String(cString: val)
                    }
                }
                let notif = CapturedNotification(
                    timestamp: ISO8601DateFormatter().string(from: Date()),
                    app: data["app"] ?? data["app_id"] ?? "unknown",
                    bundleId: data["bundle_id"] ?? data["app_id"] ?? "unknown",
                    title: data["title"] ?? data["titl"] ?? "",
                    body: data["body"] ?? data["subt"] ?? "",
                    category: data["category"] ?? data["cat"] ?? ""
                )
                results.append(notif)
            }
            sqlite3_finalize(stmt)
        }

        return results
    }
}

// MARK: - Distributed Notification Listener

class DistributedNotificationListener {
    var handler: ((CapturedNotification) -> Void)?

    func start() {
        DistributedNotificationCenter.default().addObserver(
            forName: nil,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let notif = CapturedNotification(
                timestamp: ISO8601DateFormatter().string(from: Date()),
                app: notification.object as? String ?? "unknown",
                bundleId: notification.name.rawValue,
                title: notification.name.rawValue,
                body: (notification.userInfo?.description) ?? "",
                category: "distributed"
            )
            self?.handler?(notif)
        }
    }
}

// MARK: - Output Handlers

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
        encoder.dateEncodingStrategy = .iso8601

        // Ensure output directory exists
        if let outputFile = outputFile {
            let dir = (outputFile as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }

    func emit(_ notification: CapturedNotification) {
        guard let jsonData = try? encoder.encode(notification),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }

        // stdout
        if useStdout {
            print(jsonString)
            fflush(stdout)
        }

        // File
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

        // Webhook
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
        abstract: "Capture macOS notifications from all apps and output as JSON lines."
    )

    @Flag(name: .long, help: "Run as background daemon")
    var daemon = false

    @Option(name: .long, help: "Webhook URL to POST notifications to")
    var webhook: String?

    @Option(name: .long, help: "Output file path (default: ~/.notification-listener/notifications.jsonl)")
    var output: String?

    @Flag(name: .long, help: "Stream JSON lines to stdout")
    var stdout = false

    @Option(name: .long, help: "Poll interval in seconds for DB polling")
    var pollInterval: Double = 2.0

    @Option(name: .long, help: "Filter by app name (comma-separated)")
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

        fputs("notification-listener starting...\n", stderr)
        fputs("Output file: \(effectiveOutput)\n", stderr)
        if let url = webhookURL { fputs("Webhook: \(url)\n", stderr) }
        fputs("Stdout: \(useStdout)\n", stderr)

        let emitFiltered: (CapturedNotification) -> Void = { notif in
            if let filter = appFilter {
                guard filter.contains(notif.app.lowercased()) || filter.contains(notif.bundleId.lowercased()) else { return }
            }
            outputManager.emit(notif)
        }

        // Start distributed notification listener
        let distListener = DistributedNotificationListener()
        distListener.handler = emitFiltered
        distListener.start()
        fputs("Listening for distributed notifications...\n", stderr)

        // Start DB poller
        let poller = NotificationDBPoller()

        // Set up polling timer
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler {
            let newNotifs = poller.pollNewNotifications()
            for notif in newNotifs {
                emitFiltered(notif)
            }
        }
        timer.resume()

        // Handle SIGINT/SIGTERM gracefully
        signal(SIGINT) { _ in
            fputs("\nShutting down...\n", stderr)
            Darwin.exit(0)
        }
        signal(SIGTERM) { _ in
            fputs("\nShutting down...\n", stderr)
            Darwin.exit(0)
        }

        // Run the runloop
        RunLoop.main.run()
    }
}
