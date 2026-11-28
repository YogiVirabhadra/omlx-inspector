import Foundation

// Raw values are the strings written by earlier builds. Unknown values fall back
// at the preferences boundary; logger names remain open-ended source data.
enum BrowsingMode: String, CaseIterable {
    case executions = "Executions"
    case logRecords = "Log Records"
}
enum InspectorMode: String, CaseIterable {
    case readable = "Readable"
    case structured = "Structured"
    case source = "Source"

    /// A one-line description shown under the representation picker.
    var purpose: String {
        switch self {
        case .readable: "Understand · a concise interpretation"
        case .structured: "Investigate · explore the parsed fields"
        case .source: "Verify · the original log record"
        }
    }
}
enum RecordInspectorMode: String, CaseIterable {
    case structured = "Structured"
    case source = "Source"
}
enum Appearance: String, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
}
enum RecordLevel: String, CaseIterable {
    case all = "All levels"
    case trace = "TRACE"
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"
    case critical = "CRITICAL"
    func includes(_ level: String) -> Bool { self == .all || rawValue == level }
}
enum LoggerFilter: Hashable {
    case all
    case named(String)
    func includes(_ logger: String) -> Bool {
        switch self {
        case .all: true
        case .named(let name): name == logger
        }
    }
}

/// `UserDefaults` keys. The raw values are what earlier builds wrote; never change them.
enum PreferenceKey: String {
    case appearance, mode, showContext, filter, monitoring, browsingMode, recordMode
    /// The path of the last opened log.
    case lastSource
    /// The selected event, with the inode and digest that must still match to restore it.
    case selectedEvent, selectedInode, selectedDigest
    /// The selected record, with the inode and digest that must still match to restore it.
    case selectedRecord, recordInode, recordDigest
}

extension UserDefaults {
    func string(for key: PreferenceKey) -> String? { string(forKey: key.rawValue) }
    func bool(for key: PreferenceKey) -> Bool { bool(forKey: key.rawValue) }
    func object(for key: PreferenceKey) -> Any? { object(forKey: key.rawValue) }
    func set(_ value: Any?, for key: PreferenceKey) { set(value, forKey: key.rawValue) }
}
