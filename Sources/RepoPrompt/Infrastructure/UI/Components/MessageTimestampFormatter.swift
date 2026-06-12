import Foundation

/// Formats visible Agent Mode message/tool/log timestamps.
///
/// The disabled path intentionally preserves the historical `HH:mm:ss` output.
enum MessageTimestampFormatter {
    private static let cache = MessageTimestampFormatterCache()

    static func string(
        from date: Date,
        includeDateContext: Bool,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let time = formatted(date, format: "HH:mm:ss", calendar: calendar, locale: locale)
        guard includeDateContext else {
            return time
        }

        if calendar.isDate(date, inSameDayAs: now) {
            return time
        }

        if let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)),
           calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "\(yesterdayLabel(for: date, relativeTo: now, calendar: calendar, locale: locale)) \(time)"
        }

        if isSameCalendarWeek(date, now, calendar: calendar) {
            return "\(formatted(date, template: "EEE", calendar: calendar, locale: locale)) \(time)"
        }

        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return "\(formatted(date, template: "MMM d", calendar: calendar, locale: locale)), \(time)"
        }

        return "\(formatted(date, template: "MMM d y", calendar: calendar, locale: locale)), \(time)"
    }

    private static func isSameCalendarWeek(_ lhs: Date, _ rhs: Date, calendar: Calendar) -> Bool {
        let lhsComponents = calendar.dateComponents([.weekOfYear, .yearForWeekOfYear], from: lhs)
        let rhsComponents = calendar.dateComponents([.weekOfYear, .yearForWeekOfYear], from: rhs)
        return lhsComponents.weekOfYear == rhsComponents.weekOfYear
            && lhsComponents.yearForWeekOfYear == rhsComponents.yearForWeekOfYear
    }

    private static func yesterdayLabel(
        for date: Date,
        relativeTo now: Date,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now).localizedCapitalized
    }

    private static func formatted(
        _ date: Date,
        format: String,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        cache.string(from: date, format: format, calendar: calendar, locale: locale)
    }

    private static func formatted(
        _ date: Date,
        template: String,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        cache.string(from: date, template: template, calendar: calendar, locale: locale)
    }
}

private final class MessageTimestampFormatterCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedFormatters: [CacheKey: DateFormatter] = [:]

    func string(
        from date: Date,
        format: String,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        string(
            from: date,
            key: CacheKey(
                format: format,
                isTemplate: false,
                calendar: calendar,
                localeIdentifier: locale.identifier
            ),
            calendar: calendar,
            locale: locale
        )
    }

    func string(
        from date: Date,
        template: String,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        string(
            from: date,
            key: CacheKey(
                format: template,
                isTemplate: true,
                calendar: calendar,
                localeIdentifier: locale.identifier
            ),
            calendar: calendar,
            locale: locale
        )
    }

    private func string(
        from date: Date,
        key: CacheKey,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        lock.lock()
        defer { lock.unlock() }

        if let formatter = cachedFormatters[key] {
            return formatter.string(from: date)
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        if key.isTemplate {
            formatter.setLocalizedDateFormatFromTemplate(key.format)
        } else {
            formatter.dateFormat = key.format
        }
        cachedFormatters[key] = formatter
        return formatter.string(from: date)
    }

    private struct CacheKey: Hashable {
        let format: String
        let isTemplate: Bool
        let calendarIdentifier: Calendar.Identifier
        let timeZoneIdentifier: String
        let localeIdentifier: String
        let firstWeekday: Int
        let minimumDaysInFirstWeek: Int

        init(format: String, isTemplate: Bool, calendar: Calendar, localeIdentifier: String) {
            self.format = format
            self.isTemplate = isTemplate
            calendarIdentifier = calendar.identifier
            timeZoneIdentifier = calendar.timeZone.identifier
            self.localeIdentifier = localeIdentifier
            firstWeekday = calendar.firstWeekday
            minimumDaysInFirstWeek = calendar.minimumDaysInFirstWeek
        }
    }
}
