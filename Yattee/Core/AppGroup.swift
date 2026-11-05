import Foundation

enum AppGroup {
    static let identifier = "group.stream.yattee.app.shared"


    static var defaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }
}
