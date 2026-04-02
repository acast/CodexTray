import AppKit
import Foundation

private struct RateLimitWindow {
    let usedPercent: Int
    let remainingPercent: Int
    let resetDate: Date
}

private struct DailyUsage {
    let day: Date
    let officialSpentPercent: Int
    let displaySpentPercent: Double?
    let spentTokens: Int
}

private struct RateLimitSnapshot {
    let shortWindow: RateLimitWindow?
    let weeklyWindow: RateLimitWindow?
    let todayUsage: DailyUsage?
    let estimateText: String?
}

private struct SessionEvent: Decodable {
    let timestamp: String?
    let payload: Payload?

    struct Payload: Decodable {
        let type: String?
        let rateLimits: RateLimits?
        let info: Info?

        enum CodingKeys: String, CodingKey {
            case type
            case rateLimits = "rate_limits"
            case info
        }
    }

    struct RateLimits: Decodable {
        let primary: Primary?
        let secondary: Primary?
    }

    struct Primary: Decodable {
        let usedPercent: Double?
        let resetsAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetsAt = "resets_at"
        }
    }

    struct Info: Decodable {
        let totalTokenUsage: TokenUsage?
        let lastTokenUsage: TokenUsage?

        enum CodingKeys: String, CodingKey {
            case totalTokenUsage = "total_token_usage"
            case lastTokenUsage = "last_token_usage"
        }
    }

    struct TokenUsage: Decodable {
        let totalTokens: Int?

        enum CodingKeys: String, CodingKey {
            case totalTokens = "total_tokens"
        }
    }
}

private struct TodayProgressSample {
    let date: Date
    let usedPercent: Double
    let tokenIncrement: Int
}

private enum RateLimitReader {
    static func latestSnapshot() -> RateLimitSnapshot? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var candidates: [(url: URL, modifiedAt: Date)] = []

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate else {
                continue
            }
            candidates.append((fileURL, modifiedAt))
        }

        let decoder = JSONDecoder()
        let sortedCandidates = candidates.sorted { $0.modifiedAt > $1.modifiedAt }
        let latestCandidates = sortedCandidates.prefix(5)

        var bestWindows: (shortWindow: RateLimitWindow?, weeklyWindow: RateLimitWindow?, eventTimestamp: Date)?
        let todayKey = dayFormatter.string(from: Date())
        var weeklyUsedByDay: [String: (date: Date, usedPercent: Double)] = [:]
        var tokensByDay: [String: Int] = [:]
        var todaySamples: [TodayProgressSample] = []

        for candidate in latestCandidates {
            guard let content = tailString(for: candidate.url, maxBytes: 256 * 1024) else { continue }

            for line in content.split(separator: "\n").reversed() {
                guard let data = line.data(using: .utf8),
                      let event = try? decoder.decode(SessionEvent.self, from: data),
                      event.payload?.type == "token_count",
                      let rateLimits = event.payload?.rateLimits else {
                    continue
                }

                let eventDate = event.timestamp.flatMap(parseISO8601Date) ?? candidate.modifiedAt
                let shortWindow = makeWindow(from: rateLimits.primary)
                let weeklyWindow = makeWindow(from: rateLimits.secondary ?? rateLimits.primary)

                if bestWindows == nil || eventDate > bestWindows!.eventTimestamp {
                    bestWindows = (shortWindow, weeklyWindow, eventDate)
                }
                break
            }
        }

        for candidate in sortedCandidates.prefix(14) {
            guard let content = try? String(contentsOf: candidate.url, encoding: .utf8) else { continue }

            var previousTotalTokens: Int?

            for line in content.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let event = try? decoder.decode(SessionEvent.self, from: data),
                      event.payload?.type == "token_count",
                      let rateLimits = event.payload?.rateLimits,
                      let eventDate = event.timestamp.flatMap(parseISO8601Date),
                      let weeklyUsedPercent = (rateLimits.secondary ?? rateLimits.primary)?.usedPercent else {
                    continue
                }

                let dayKey = dayFormatter.string(from: eventDate)

                if let existing = weeklyUsedByDay[dayKey], existing.date >= eventDate {
                    continue
                }

                weeklyUsedByDay[dayKey] = (eventDate, weeklyUsedPercent)

                let tokenIncrement = makeTokenIncrement(info: event.payload?.info, previousTotalTokens: &previousTotalTokens)
                if tokenIncrement > 0 {
                    tokensByDay[dayKey, default: 0] += tokenIncrement
                }

                if dayKey == todayKey {
                    todaySamples.append(
                        TodayProgressSample(
                            date: eventDate,
                            usedPercent: weeklyUsedPercent,
                            tokenIncrement: max(0, tokenIncrement)
                        )
                    )
                }
            }
        }

        let todayUsage = buildTodayUsage(
            from: weeklyUsedByDay,
            tokensByDay: tokensByDay,
            todaySamples: todaySamples
        )
        guard let bestWindows else {
            return nil
        }

        return RateLimitSnapshot(
            shortWindow: bestWindows.shortWindow,
            weeklyWindow: bestWindows.weeklyWindow,
            todayUsage: todayUsage,
            estimateText: makeEstimateText(for: bestWindows.weeklyWindow)
        )
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func makeISO8601Formatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }

    private static func parseISO8601Date(_ value: String) -> Date? {
        let fractionalFormatter = makeISO8601Formatter(fractionalSeconds: true)
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        let standardFormatter = makeISO8601Formatter(fractionalSeconds: false)
        return standardFormatter.date(from: value)
    }

    private static func makeWindow(from raw: SessionEvent.Primary?) -> RateLimitWindow? {
        guard let raw,
              let usedPercent = raw.usedPercent,
              let resetsAt = raw.resetsAt else {
            return nil
        }

        let used = Int(usedPercent.rounded())
        return RateLimitWindow(
            usedPercent: used,
            remainingPercent: max(0, 100 - used),
            resetDate: Date(timeIntervalSince1970: resetsAt)
        )
    }

    private static func buildTodayUsage(
        from weeklyUsedByDay: [String: (date: Date, usedPercent: Double)],
        tokensByDay: [String: Int],
        todaySamples: [TodayProgressSample]
    ) -> DailyUsage? {
        let ordered = weeklyUsedByDay.values.sorted { $0.date < $1.date }
        guard !ordered.isEmpty else { return nil }

        var result: [DailyUsage] = []
        var previousUsed: Double?

        for entry in ordered {
            let spent: Double
            if let previousUsed {
                spent = entry.usedPercent >= previousUsed ? (entry.usedPercent - previousUsed) : entry.usedPercent
            } else {
                spent = entry.usedPercent
            }

            let dayKey = dayFormatter.string(from: entry.date)
            let officialSpentPercent = max(0, Int(spent.rounded(.down)))

            result.append(
                DailyUsage(
                    day: entry.date,
                    officialSpentPercent: officialSpentPercent,
                    displaySpentPercent: nil,
                    spentTokens: max(0, tokensByDay[dayKey] ?? 0)
                )
            )
            previousUsed = entry.usedPercent
        }

        let todayKey = dayFormatter.string(from: Date())
        guard let todayIndex = result.lastIndex(where: { dayFormatter.string(from: $0.day) == todayKey }) else {
            return nil
        }

        let displaySpentPercent = makeDisplayTodayPercent(
            todayUsage: result[todayIndex],
            previousDayUsedPercent: previousDayUsedPercent(from: ordered, todayKey: todayKey),
            todaySamples: todaySamples
        )

        return DailyUsage(
            day: result[todayIndex].day,
            officialSpentPercent: result[todayIndex].officialSpentPercent,
            displaySpentPercent: displaySpentPercent,
            spentTokens: result[todayIndex].spentTokens
        )
    }

    private static func previousDayUsedPercent(
        from ordered: [(date: Date, usedPercent: Double)],
        todayKey: String
    ) -> Double? {
        let previousDay = ordered.last { dayFormatter.string(from: $0.date) != todayKey }
        return previousDay?.usedPercent
    }

    private static func makeDisplayTodayPercent(
        todayUsage: DailyUsage,
        previousDayUsedPercent: Double?,
        todaySamples: [TodayProgressSample]
    ) -> Double? {
        guard todayUsage.officialSpentPercent > 0 || todayUsage.spentTokens > 0 else {
            return Double(todayUsage.officialSpentPercent)
        }

        let sortedSamples = todaySamples.sorted { $0.date < $1.date }
        guard !sortedSamples.isEmpty else {
            return Double(todayUsage.officialSpentPercent)
        }

        let baselineUsedPercent = previousDayUsedPercent ?? sortedSamples.first!.usedPercent
        var stepTokenBuckets: [Int] = []
        var currentUsedPercent = sortedSamples.first!.usedPercent
        var currentStepTokens = 0

        for sample in sortedSamples {
            if sample.usedPercent > currentUsedPercent {
                if currentStepTokens > 0 {
                    stepTokenBuckets.append(currentStepTokens)
                }

                currentUsedPercent = sample.usedPercent
                currentStepTokens = sample.tokenIncrement
            } else {
                currentStepTokens += sample.tokenIncrement
            }
        }

        let officialTodayPercent = todayUsage.officialSpentPercent
        let currentRawStep = Int(max(0, floor(currentUsedPercent - baselineUsedPercent)))
        guard currentRawStep == officialTodayPercent else {
            return Double(officialTodayPercent)
        }

        guard let previousCompletedStepTokens = stepTokenBuckets.last, previousCompletedStepTokens > 0 else {
            return Double(officialTodayPercent)
        }

        let progress = min(max(Double(currentStepTokens) / Double(previousCompletedStepTokens), 0), 0.9)
        return Double(officialTodayPercent) + progress
    }

    private static func makeTokenIncrement(info: SessionEvent.Info?, previousTotalTokens: inout Int?) -> Int {
        if let totalTokens = info?.totalTokenUsage?.totalTokens {
            defer { previousTotalTokens = totalTokens }

            guard let previousTotalTokens else {
                return max(0, totalTokens)
            }

            return totalTokens >= previousTotalTokens ? (totalTokens - previousTotalTokens) : totalTokens
        }

        if let lastTokens = info?.lastTokenUsage?.totalTokens {
            return max(0, lastTokens)
        }

        return 0
    }

    private static func makeEstimateText(for weeklyWindow: RateLimitWindow?) -> String? {
        guard let weeklyWindow else { return nil }

        let now = Date()
        let remainingSeconds = max(0, weeklyWindow.resetDate.timeIntervalSince(now))
        let totalHours = Int(remainingSeconds / 3600)
        let days = totalHours / 24
        let hours = totalHours % 24

        let daysForBudget = max(days + (hours > 0 ? 1 : 0), 1)
        let perDay = max(0, Int(Double(weeklyWindow.remainingPercent) / Double(daysForBudget)))

        return "\(perDay)%  \(days)d \(hours)h"
    }

    private static func tailString(for url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }

        defer {
            try? handle.close()
        }

        guard let fileSize = try? handle.seekToEnd() else {
            return nil
        }

        let startOffset = fileSize > UInt64(maxBytes) ? fileSize - UInt64(maxBytes) : 0

        do {
            try handle.seek(toOffset: startOffset)
            let data = handle.readDataToEndOfFile()
            guard var text = String(data: data, encoding: .utf8) else {
                return nil
            }

            if startOffset > 0, let newlineIndex = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: newlineIndex)...])
            }

            return text
        } catch {
            return nil
        }
    }
}

@MainActor
private final class StatusBadgeView: NSView {
    private let label = "CODEX"
    private let contentWidth: CGFloat = 31
    private let contentHeight: CGFloat = 19

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: contentWidth, height: contentHeight)
    }

    func makeImage(value: String) -> NSImage {
        let image = NSImage(size: intrinsicContentSize)
        image.lockFocus()
        drawBadge(value: value)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func drawBadge(value: String) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7, weight: .light),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraphStyle,
        ]
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraphStyle,
        ]

        NSAttributedString(string: label, attributes: labelAttributes)
            .draw(with: CGRect(x: 0, y: 13, width: contentWidth, height: 7))
        NSAttributedString(string: value, attributes: valueAttributes)
            .draw(with: CGRect(x: 0, y: 2, width: contentWidth, height: 13))
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let statusBadgeView = StatusBadgeView()
    private let menu = NSMenu()
    private var refreshTimer: Timer?
    private let menuWidth: CGFloat = 220
    private let models = [
        "GPT-5.4",
        "GPT-5.4-Mini",
        "GPT-5.3-Codex",
        "GPT-5.2-Codex",
        "GPT-5.2",
        "GPT-5.1-Codex-Max",
        "GPT-5.1-Codex-Mini",
    ]
    private let configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
    private let resetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter
    }()
    private let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !shouldTerminateAsDuplicate() else {
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem

        if let button = statusItem.button {
            button.image = statusBadgeView.makeImage(value: "0%")
            button.imagePosition = .imageOnly
            button.appearsDisabled = false
            button.alignment = .center
            button.lineBreakMode = .byClipping
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")
        }

        menu.autoenablesItems = false
        statusItem.menu = menu

        refresh()

        refreshTimer = Timer.scheduledTimer(timeInterval: 60, target: self, selector: #selector(handleRefreshTimer), userInfo: nil, repeats: true)
        RunLoop.main.add(refreshTimer!, forMode: .common)
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func refresh() {
        let snapshot = RateLimitReader.latestSnapshot()
        updateButton(snapshot: snapshot)
        rebuildMenu(snapshot: snapshot)
    }

    private func rebuildMenu(snapshot: RateLimitSnapshot?) {
        menu.removeAllItems()

        if let snapshot {
            addSectionTitle("Rate limits remaining")

            addStatLine(
                label: "5h",
                value: snapshot.shortWindow.map { "\($0.remainingPercent)%  \(clockFormatter.string(from: $0.resetDate))" } ?? "--"
            )
            addStatLine(
                label: "Weekly",
                value: snapshot.weeklyWindow.map { "\($0.remainingPercent)%  \(resetFormatter.string(from: $0.resetDate))" } ?? "--"
            )
            addStatLine(label: "Estimate", value: snapshot.estimateText ?? "--")
            addStatLine(label: "Today", value: formatTodayUsage(snapshot.todayUsage))

            menu.addItem(.separator())
        } else {
            addSectionTitle("No Codex stats found")
        }

        menu.addItem(.separator())
        addSectionTitle("Speed")
        addSpeedItems()
        menu.addItem(.separator())
        addSectionTitle("Multiagent")
        addMultiagentItems()
        menu.addItem(.separator())
        addSectionTitle("Select model")
        addModelItems()
        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(handleRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func handleRefresh() {
        refresh()
    }

    @objc private func handleRefreshTimer() {
        refresh()
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let model = sender.representedObject as? String else { return }
        writeSelectedModel(model)
        rebuildMenu(snapshot: RateLimitReader.latestSnapshot())
    }

    @objc private func selectSpeed(_ sender: NSMenuItem) {
        guard let speed = sender.representedObject as? String else { return }
        writeReasoningEffort(speed == "Standard" ? "medium" : "low")
        rebuildMenu(snapshot: RateLimitReader.latestSnapshot())
    }

    @objc private func selectMultiagent(_ sender: NSMenuItem) {
        guard let enabled = sender.representedObject as? Bool else { return }
        writeMultiAgent(enabled)
        rebuildMenu(snapshot: RateLimitReader.latestSnapshot())
    }

    private func updateButton(snapshot: RateLimitSnapshot?) {
        guard let button = statusItem?.button else { return }
        let value = "\(snapshot?.weeklyWindow?.remainingPercent ?? 0)%"
        button.image = statusBadgeView.makeImage(value: value)
        button.imagePosition = .imageOnly
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        statusItem?.length = statusBadgeView.intrinsicContentSize.width + 12
        button.toolTip = snapshot.map {
            let weeklyText = $0.weeklyWindow.map { "Weekly left: \($0.remainingPercent)%\nResets \(resetFormatter.string(from: $0.resetDate))" } ?? "Weekly left: unavailable"
            let shortText = $0.shortWindow.map { "5h left: \($0.remainingPercent)%\nResets \(clockFormatter.string(from: $0.resetDate))" } ?? "5h left: unavailable"
            return "\(shortText)\n\(weeklyText)"
        } ?? "Codex weekly remaining: unavailable"
    }

    private func formatTodayUsage(_ usage: DailyUsage?) -> String {
        guard let usage else {
            return "0%  ~0t"
        }

        return "\(formatPercent(usage.displaySpentPercent, fallback: usage.officialSpentPercent))  ~\(formatTokens(usage.spentTokens))t"
    }

    private func formatPercent(_ value: Double?, fallback: Int) -> String {
        guard let value else {
            return "\(fallback)%"
        }

        let roundedToTenth = (value * 10).rounded() / 10
        let integerPart = Int(roundedToTenth.rounded(.down))
        let decimalDigit = Int(((roundedToTenth - Double(integerPart)) * 10).rounded())

        if decimalDigit <= 0 {
            return "\(integerPart)%"
        }

        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumIntegerDigits = 1
        let integerText = formatter.string(from: NSNumber(value: integerPart)) ?? "\(integerPart)"
        return "\(integerText).\(decimalDigit)%"
    }

    private func formatTokens(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale.current
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func shouldTerminateAsDuplicate() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return false
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        return running.contains { Int32($0.processIdentifier) != currentPID }
    }

    private func addSectionTitle(_ text: String) {
        let item = NSMenuItem()
        item.isEnabled = false
        item.view = makeSectionTitleView(text: text)
        menu.addItem(item)
    }

    private func addStatLine(label: String, value: String) {
        let item = NSMenuItem()
        item.isEnabled = false
        item.view = makeStatLineView(label: label, value: value)
        menu.addItem(item)
    }

    private func addModelItems() {
        let selectedModel = readSelectedModel() ?? "GPT-5.4-Mini"

        for model in models {
            let item = NSMenuItem(title: model, action: #selector(selectModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = model
            item.state = model == selectedModel ? .on : .off
            menu.addItem(item)
        }
    }

    private func addSpeedItems() {
        let selectedSpeed = (readReasoningEffort() == "medium") ? "Standard" : "Fast"

        for speed in ["Standard", "Fast"] {
            let item = NSMenuItem(title: speed, action: #selector(selectSpeed(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = speed
            item.state = speed == selectedSpeed ? .on : .off
            menu.addItem(item)
        }
    }

    private func addMultiagentItems() {
        let selected = readMultiAgent()

        for option in [true, false] {
            let item = NSMenuItem(title: option ? "On" : "Off", action: #selector(selectMultiagent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option
            item.state = option == selected ? .on : .off
            menu.addItem(item)
        }
    }

    private func readSelectedModel() -> String? {
        guard let content = try? String(contentsOf: configURL, encoding: .utf8) else {
            return nil
        }

        let pattern = #"(?m)^model\s*=\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(content.startIndex..., in: content)
        guard let match = regex.firstMatch(in: content, options: [], range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: content) else {
            return nil
        }

        return displayName(forConfigModel: String(content[valueRange]))
    }

    private func writeSelectedModel(_ displayModel: String) {
        let configModel = configName(forDisplayModel: displayModel)
        updateOrInsertTopLevelKey("model", value: #"\"\#(configModel)\""#)
    }

    private func configName(forDisplayModel displayModel: String) -> String {
        switch displayModel {
        case "GPT-5.4":
            return "gpt-5.4"
        case "GPT-5.4-Mini":
            return "gpt-5.4-mini"
        case "GPT-5.3-Codex":
            return "gpt-5.3-codex"
        case "GPT-5.2-Codex":
            return "gpt-5.2-codex"
        case "GPT-5.2":
            return "gpt-5.2"
        case "GPT-5.1-Codex-Max":
            return "gpt-5.1-codex-max"
        case "GPT-5.1-Codex-Mini":
            return "gpt-5.1-codex-mini"
        default:
            return displayModel.lowercased()
        }
    }

    private func displayName(forConfigModel configModel: String) -> String {
        switch configModel {
        case "gpt-5.4":
            return "GPT-5.4"
        case "gpt-5.4-mini":
            return "GPT-5.4-Mini"
        case "gpt-5.3-codex":
            return "GPT-5.3-Codex"
        case "gpt-5.2-codex":
            return "GPT-5.2-Codex"
        case "gpt-5.2":
            return "GPT-5.2"
        case "gpt-5.1-codex-max":
            return "GPT-5.1-Codex-Max"
        case "gpt-5.1-codex-mini":
            return "GPT-5.1-Codex-Mini"
        default:
            return configModel.uppercased()
        }
    }

    private func readReasoningEffort() -> String? {
        readTopLevelStringValue(for: "model_reasoning_effort")
    }

    private func writeReasoningEffort(_ effort: String) {
        updateOrInsertTopLevelKey("model_reasoning_effort", value: #"\"\#(effort)\""#)
    }

    private func readMultiAgent() -> Bool {
        guard let content = try? String(contentsOf: configURL, encoding: .utf8),
              let featuresRange = featuresSectionRange(in: content) else {
            return true
        }

        guard let regex = try? NSRegularExpression(pattern: #"(?m)^multi_agent\s*=\s*(true|false)"#) else {
            return true
        }

        guard let match = regex.firstMatch(in: content, options: [], range: featuresRange),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: content) else {
            return true
        }

        return String(content[valueRange]) == "true"
    }

    private func writeMultiAgent(_ enabled: Bool) {
        let original = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let replacement = "multi_agent = \(enabled ? "true" : "false")"

        if let featuresRange = featuresSectionRange(in: original),
           let regex = try? NSRegularExpression(pattern: #"(?m)^multi_agent\s*=\s*(true|false)"#) {
            if regex.firstMatch(in: original, options: [], range: featuresRange) != nil {
                let updated = regex.stringByReplacingMatches(in: original, options: [], range: featuresRange, withTemplate: replacement)
                try? updated.write(to: configURL, atomically: true, encoding: .utf8)
                return
            }

            if let insertRange = Range(featuresRange, in: original) {
                var updated = original
                updated.insert(contentsOf: replacement + "\n", at: insertRange.upperBound)
                try? updated.write(to: configURL, atomically: true, encoding: .utf8)
                return
            }
        }

        let separator = original.isEmpty || original.hasSuffix("\n") ? "" : "\n"
        let updated = original + separator + "[features]\n" + replacement + "\n"
        try? updated.write(to: configURL, atomically: true, encoding: .utf8)
    }

    private func readTopLevelStringValue(for key: String) -> String? {
        guard let content = try? String(contentsOf: configURL, encoding: .utf8) else {
            return nil
        }

        let pattern = #"(?m)^\#(key)\s*=\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(content.startIndex..., in: content)
        guard let match = regex.firstMatch(in: content, options: [], range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: content) else {
            return nil
        }

        return String(content[valueRange])
    }

    private func updateOrInsertTopLevelKey(_ key: String, value: String) {
        let original = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let pattern = #"(?m)^\#(key)\s*=\s*.+$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return
        }

        let replacement = "\(key) = \(value)"
        let range = NSRange(original.startIndex..., in: original)
        let updated: String

        if regex.firstMatch(in: original, options: [], range: range) != nil {
            updated = regex.stringByReplacingMatches(in: original, options: [], range: range, withTemplate: replacement)
        } else if original.isEmpty {
            updated = replacement + "\n"
        } else {
            updated = replacement + "\n" + original
        }

        try? updated.write(to: configURL, atomically: true, encoding: .utf8)
    }

    private func featuresSectionRange(in content: String) -> NSRange? {
        let nsContent = content as NSString
        let headerRange = nsContent.range(of: "[features]")
        guard headerRange.location != NSNotFound else { return nil }

        let start = headerRange.location + headerRange.length + 1
        guard start <= nsContent.length else {
            return NSRange(location: headerRange.location + headerRange.length, length: 0)
        }

        let searchRange = NSRange(location: start, length: nsContent.length - start)
        let nextSection = nsContent.range(of: "\n[", options: [], range: searchRange)

        if nextSection.location == NSNotFound {
            return NSRange(location: start, length: nsContent.length - start)
        }

        return NSRange(location: start, length: nextSection.location - start)
    }

    private func makeSectionTitleView(text: String) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 24))

        let titleLabel = NSTextField(labelWithString: text)
        titleLabel.font = .menuFont(ofSize: 13)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.frame = NSRect(x: 14, y: 3, width: menuWidth - 28, height: 17)
        container.addSubview(titleLabel)

        return container
    }

    private func makeStatLineView(label: String, value: String) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 24))

        let labelField = NSTextField(labelWithString: label)
        labelField.font = .menuFont(ofSize: 13)
        labelField.textColor = .labelColor
        labelField.lineBreakMode = .byTruncatingTail
        labelField.frame = NSRect(x: 14, y: 3, width: 64, height: 17)

        let valueField = NSTextField(labelWithString: value)
        valueField.font = .menuFont(ofSize: 13)
        valueField.textColor = .secondaryLabelColor
        valueField.alignment = .right
        valueField.frame = NSRect(x: 84, y: 3, width: menuWidth - 98, height: 17)

        container.addSubview(labelField)
        container.addSubview(valueField)
        return container
    }
}

@main
enum CodexTray {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
