import Foundation

/// Checks the GitHub repo named in Info.plist (XSUpdateRepo, "owner/name")
/// for a newer release. It only tells you; downloading stays in your hands.
enum Updater {
    enum Result {
        case notConfigured
        case noReleases
        case upToDate(String)
        case available(version: String, url: URL)
        case failed(String)
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var repo: String? {
        let env = ProcessInfo.processInfo.environment["XSWITCHER_UPDATE_REPO"]
        let plist = Bundle.main.object(forInfoDictionaryKey: "XSUpdateRepo") as? String
        let r = (env?.isEmpty == false ? env : plist)?.trimmingCharacters(in: .whitespaces) ?? ""
        return r.contains("/") ? r : nil
    }

    private static let lastCheckKey = "lastUpdateCheck"

    static var isDue: Bool {
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        return Date().timeIntervalSince1970 - last > 24 * 3600
    }

    static func check(completion: @escaping @MainActor (Result) -> Void) {
        guard let repo, let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            Task { @MainActor in completion(.notConfigured) }
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("XSwitcher-update-check", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, response, error in
            let result: Result
            if let error {
                result = .failed(error.localizedDescription)
            } else if (response as? HTTPURLResponse)?.statusCode == 404 {
                result = .noReleases
            } else if let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String {
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                let page = (json["html_url"] as? String).flatMap(URL.init(string:))
                    ?? URL(string: "https://github.com/\(repo)/releases")!
                result = isNewer(version, than: currentVersion) ? .available(version: version, url: page) : .upToDate(currentVersion)
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
            } else {
                result = .failed("unexpected reply from GitHub")
            }
            Task { @MainActor in completion(result) }
        }.resume()
    }

    /// Compares dotted version numbers: 0.10.0 is newer than 0.9.2.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
