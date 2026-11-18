import Foundation

enum AppBuildInfo {
    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? String(localized: "Unknown")
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }

    #if DEBUG
    static let debugVersionString: String = {
        let label = "Debug · \(versionString)"
        guard let url = Bundle.main.url(forResource: "DebugCommit", withExtension: "txt"),
              let commit = try? String(contentsOf: url, encoding: .utf8),
              !commit.isEmpty else { return label }
        return "\(label) · \(commit)"
    }()
    #endif
}
