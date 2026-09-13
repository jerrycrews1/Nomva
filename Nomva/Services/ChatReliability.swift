import Foundation
import SwiftData

@MainActor
enum FoodMutationPolicy {
    static func uniqueEntry(named target: String, in entries: [FoodEntry]) -> FoodEntry? {
        let key = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        if let id = UUID(uuidString: target) { return entries.first { $0.id == id } }
        let matches = entries.filter {
            let fullName = [ $0.brand, $0.name ].compactMap { $0 }.joined(separator: " ").lowercased()
            return $0.name.lowercased() == key || fullName == key
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func savedFoodReply(_ result: FoodLoggingService.LoggingResult, entries: [FoodEntry]) -> String {
        var lines = entries.enumerated().map { index, entry in
            let estimated = entry.source == "web_estimate" ||
                (result.evidenceDrafts.indices.contains(index) && result.evidenceDrafts[index].sourceType == "web_estimate")
            return "✓ \(entry.name) (\(entry.portionDescription)) — \(entry.calories.safeRoundedInt) cal\(estimated ? " estimated" : "")"
        }
        if !result.unresolvedFoods.isEmpty {
            lines.append("Not added: \(result.unresolvedFoods.joined(separator: ", ")). Tell me more about just these foods, or search for them.")
        }
        return lines.joined(separator: "\n")
    }

    static func commitNewLog(_ result: FoodLoggingService.LoggingResult, in context: ModelContext, timestamp: Date) throws -> [FoodEntry] {
        guard case .logFood(let entries) = result.action, !entries.isEmpty else { return [] }
        do {
            let calendar = Calendar.current
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: timestamp))!
            let base = min(timestamp, dayEnd.addingTimeInterval(-Double(entries.count)))
            for (index, entry) in entries.enumerated() {
                entry.date = base.addingTimeInterval(TimeInterval(index))
                context.insert(entry)
            }
            try context.save()
            return entries
        } catch {
            context.rollback()
            throw error
        }
    }

    static func affectedFoodIDs(_ result: FoodLoggingService.LoggingResult) -> [UUID] {
        switch result.action {
        case .compound(let children): return children.flatMap(affectedFoodIDs)
        case .logFood(let foods), .replaceEntryById(_, let foods), .replaceEntry(_, let foods):
            return foods.filter { $0.modelContext != nil }.map(\.id)
        case .editEntry(let id, _, _, _, _), .moveEntry(let id, _): return [id]
        default: return []
        }
    }

    static func scopedEntries(_ entries: [FoodEntry], message: String) -> [FoodEntry] {
        let meals = ["breakfast", "lunch", "dinner", "snack"].filter {
            message.range(of: "\\b\($0)\\b", options: [.regularExpression, .caseInsensitive]) != nil
        }
        guard meals.count == 1 else { return entries }
        return entries.filter { $0.meal == meals[0] }
    }
}

enum ChatDateResolver {
    static func resolve(_ message: String, selectedDate: Date, now: Date = .now, calendar: Calendar = .current) -> Date {
        parsedDates(message, now: now, calendar: calendar).dates.first ?? selectedDate
    }

    static func validationIssue(_ message: String, now: Date = .now, calendar: Calendar = .current) -> String? {
        let parsed = parsedDates(message, now: now, calendar: calendar)
        if parsed.invalid { return "That date is not valid. Use a date such as 2026-09-12. Nothing was changed." }
        if parsed.dates.count > 1 {
            return "This request mentions more than one date. Send a separate message for each date so I can put entries in the right log. Nothing was changed."
        }
        return nil
    }

    private static func parsedDates(_ message: String, now: Date, calendar: Calendar) -> (dates: [Date], invalid: Bool) {
        var text = message.lowercased()
        var dates: [Date] = []
        var invalid = false
        for (phrase, offset) in [("day before yesterday", -2), ("yesterday", -1), ("today", 0), ("tomorrow", 1)] {
            if text.range(of: "\\b\(phrase)\\b", options: .regularExpression) != nil {
                if let date = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) { dates.append(date) }
                text = text.replacingOccurrences(of: phrase, with: "")
            }
        }
        func matches(_ pattern: String) -> [NSTextCheckingResult] {
            (try? NSRegularExpression(pattern: pattern))?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
        }
        func part(_ match: NSTextCheckingResult, _ group: Int) -> String? {
            Range(match.range(at: group), in: text).map { String(text[$0]) }
        }
        func append(year: Int, month: Int, day: Int) {
            let components = DateComponents(year: year, month: month, day: day)
            if components.isValidDate(in: calendar), let date = calendar.date(from: components) { dates.append(date) }
            else { invalid = true }
        }
        for match in matches(#"\b(\d{4})-(\d{2})-(\d{2})\b"#) {
            if let year = part(match, 1).flatMap(Int.init), let month = part(match, 2).flatMap(Int.init), let day = part(match, 3).flatMap(Int.init) {
                append(year: year, month: month, day: day)
            }
        }
        let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
        let monthPattern = #"\b(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?\b"#
        for match in matches(monthPattern) {
            guard let name = part(match, 1), let month = months.firstIndex(where: { $0.hasPrefix(String(name.prefix(3))) }), let day = part(match, 2).flatMap(Int.init) else { continue }
            append(year: part(match, 3).flatMap(Int.init) ?? calendar.component(.year, from: now), month: month + 1, day: day)
        }
        // Require a date cue so a food portion such as "1/2 cup" stays a portion.
        for match in matches(#"\b(?:on|for)\s+(\d{1,2})/(\d{1,2})(?:/(\d{4}|\d{2}))?\b"#) {
            guard let month = part(match, 1).flatMap(Int.init), let day = part(match, 2).flatMap(Int.init) else { continue }
            let yearText = part(match, 3)
            var year = yearText.flatMap(Int.init) ?? calendar.component(.year, from: now)
            if yearText?.count == 2 { year += 2000 }
            append(year: year, month: month, day: day)
        }
        let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        for (index, weekday) in weekdays.enumerated() {
            if text.range(of: "\\b(?:on|for|last)\\s+\(weekday)\\b", options: .regularExpression) != nil {
                var offset = (calendar.component(.weekday, from: now) - (index + 1) + 7) % 7
                if offset == 0 && text.contains("last \(weekday)") { offset = 7 }
                if let date = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now)) { dates.append(date) }
            }
        }
        var seen = Set<Date>()
        return (dates.filter { seen.insert($0).inserted }, invalid)
    }
}

enum ChatTurnSplitter {
    static func clauses(_ message: String) -> [String] {
        let separator = #"(?i)[;\n]+|[.!?]\s+(?=(?:I |my |log |record |add |delete |remove |change |set ))|\s+and\s+(?=(?:I\s+(?:ate|had|weigh|weighed|drank)|my\s+weight|(?:log|record|add|delete|remove|set)\s))"#
        guard let regex = try? NSRegularExpression(pattern: separator) else { return [message] }
        let separated = regex.stringByReplacingMatches(in: message, range: NSRange(message.startIndex..., in: message), withTemplate: "\n")
        return separated.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

enum WeightInputParser {
    static let kilogramsPerPound = 0.45359237

    static func pounds(in message: String) -> Double? {
        let pattern = #"(?i)\b(\d+(?:\.\d+)?)\s*(kg|kilograms?|kilos?|lbs?|pounds?)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let amountRange = Range(match.range(at: 1), in: message),
              let unitRange = Range(match.range(at: 2), in: message),
              let amount = Double(message[amountRange]) else { return nil }
        let unit = message[unitRange].lowercased()
        let pounds = unit.hasPrefix("k") ? amount / kilogramsPerPound : amount
        return pounds.isFinite && (40...1_200).contains(pounds) ? pounds : nil
    }

    static func lookbackDays(in message: String) -> Int? {
        let text = message.lowercased()
        let numbers = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "twelve": 12]
        let pattern = #"\b(\d+|one|two|three|four|five|six|seven|eight|nine|ten|twelve)\s+(days?|weeks?|months?)\b"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let numberRange = Range(match.range(at: 1), in: text), let unitRange = Range(match.range(at: 2), in: text),
           let count = Int(text[numberRange]) ?? numbers[String(text[numberRange])] {
            let unit = text[unitRange]
            return max(1, min(365, count * (unit.hasPrefix("week") ? 7 : unit.hasPrefix("month") ? 30 : 1)))
        }
        if text.range(of: #"\bmonths?\b"#, options: .regularExpression) != nil { return 30 }
        if text.range(of: #"\bweeks?\b"#, options: .regularExpression) != nil { return 7 }
        return nil
    }

    static func concernsBodyWeight(_ message: String) -> Bool {
        message.range(of: #"(?i)\b(weigh|weighed|weighing|weigh-in|weight|scale|body mass)\b"#, options: .regularExpression) != nil
    }
}

@MainActor
enum ChatHistoryPrivacy {
    static func cloudMessages(_ messages: [ChatMessage]) -> [(role: String, content: String)] {
        var includeTurn = false
        return messages.compactMap { message in
            let sensitive = WeightInputParser.concernsBodyWeight(message.content) ||
                message.content.range(of: #"(?i)\b(lb|lbs|kg|pounds|kilograms|goals?|target|remaining|left)\b"#, options: .regularExpression) != nil
            if message.role == "user" { includeTurn = !sensitive }
            guard includeTurn && !sensitive && ["user", "assistant"].contains(message.role) else { return nil }
            return (role: message.role, content: message.content)
        }.suffix(12).map { $0 }
    }
}

enum ChatTurnContext {
    static func isContinuation(_ message: String) -> Bool {
        let newRequest = #"(?i)^\s*(?:I\s+(?:ate|had|drank|weigh|weighed)|log|add|record|delete|remove|clear|set|move|show|what|how|why|when|hi|hello|thanks|cancel|stop|never mind)\b"#
        return !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && message.range(of: newRequest, options: .regularExpression) == nil
    }

    static func isFoodReference(_ message: String) -> Bool {
        message.range(of: #"(?i)\b(it|that|those|them)\b"#, options: .regularExpression) != nil &&
            message.range(of: #"(?i)\b(change|make|correct|delete|remove|actually|instead|was|were)\b"#, options: .regularExpression) != nil
    }
}
