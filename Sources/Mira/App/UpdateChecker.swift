import Foundation

// Looks for a newer GitHub release. No auto-install: the menu just links to it.
enum UpdateChecker {

    struct Release { let version: String; let url: URL }

    static func check(completion: @escaping (Release?) -> Void) {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(AppInfo.repository)/releases?per_page=10")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Mira/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data,
                  let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                completion(nil); return
            }
            let current = AppInfo.version
            let newest = list.compactMap { r -> Release? in
                guard r["draft"] as? Bool != true,
                      let tag = r["tag_name"] as? String,
                      let html = (r["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
                return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, url: html)
            }.max { isNewer($1.version, than: $0.version) }
            if let newest, isNewer(newest.version, than: current) { completion(newest) } else { completion(nil) }
        }.resume()
    }

    // Semantic-ish comparison: 1.2.10 > 1.2.9, 1.0.0 > 1.0.0-beta.2 > 1.0.0-beta.1.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func split(_ v: String) -> ([Int], [String]) {
            let parts = v.split(separator: "-", maxSplits: 1).map(String.init)
            let nums = parts[0].split(separator: ".").map { Int($0) ?? 0 }
            let pre = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
            return (nums, pre)
        }
        let (an, ap) = split(a), (bn, bp) = split(b)
        for i in 0..<max(an.count, bn.count) {
            let x = i < an.count ? an[i] : 0, y = i < bn.count ? bn[i] : 0
            if x != y { return x > y }
        }
        if ap.isEmpty != bp.isEmpty { return ap.isEmpty }          // release beats pre-release
        for i in 0..<max(ap.count, bp.count) {
            guard i < ap.count else { return false }
            guard i < bp.count else { return true }
            if let x = Int(ap[i]), let y = Int(bp[i]) { if x != y { return x > y } }
            else if ap[i] != bp[i] { return ap[i] > bp[i] }
        }
        return false
    }
}
