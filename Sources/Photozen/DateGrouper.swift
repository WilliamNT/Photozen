import Foundation

enum DateGrouper {
    private static let calendar = Calendar.current

    private static let monthYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    /// Sorts items and groups them into visual sections.
    /// When `sortByDate` is true, items are sorted chronologically and grouped by month.
    /// When `sortByDate` is false, items are sorted by name and grouped alphabetically.
    static func groupAndSort(_ items: [ImageItem], sortByDate: Bool) -> (sorted: [ImageItem], groups: [DateGroup]) {
        if sortByDate {
            return groupByDate(items)
        } else {
            return groupByName(items)
        }
    }

    private static func groupByDate(_ items: [ImageItem]) -> (sorted: [ImageItem], groups: [DateGroup]) {
        let sorted = items.sorted { ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) }

        var groups: [(key: Int, date: Date, items: [ImageItem])] = []
        for item in sorted {
            let date = item.modificationDate ?? .distantPast
            let components = calendar.dateComponents([.year, .month], from: date)
            let key = (components.year ?? 0) * 100 + (components.month ?? 0)

            if let lastIndex = groups.indices.last, groups[lastIndex].key == key {
                groups[lastIndex].items.append(item)
            } else {
                groups.append((key: key, date: date, items: [item]))
            }
        }

        let dateGroups = groups.map { group in
            DateGroup(id: "d-\(group.key)", title: monthYearFormatter.string(from: group.date), items: group.items)
        }
        return (sorted, dateGroups)
    }

    private static func groupByName(_ items: [ImageItem]) -> (sorted: [ImageItem], groups: [DateGroup]) {
        let sorted = items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        var groups: [(key: String, items: [ImageItem])] = []
        for item in sorted {
            let firstChar = item.name.first.map { String($0).uppercased() } ?? "#"
            let key = firstChar.rangeOfCharacter(from: .letters) != nil ? firstChar : "#"

            if let lastIndex = groups.indices.last, groups[lastIndex].key == key {
                groups[lastIndex].items.append(item)
            } else {
                groups.append((key: key, items: [item]))
            }
        }

        let nameGroups = groups.map { group in
            DateGroup(id: "n-\(group.key)", title: group.key, items: group.items)
        }
        return (sorted, nameGroups)
    }
}
