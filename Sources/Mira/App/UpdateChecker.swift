import Foundation

// Looks for a newer GitHub release; the menu offers to install it (Updater).
enum UpdateChecker {

    struct Release { let version: String; let url: URL }

    // nil = up to date; failure = couldn't ask GitHub (offline, rate limit...).
    static func check(completion: @escaping (Result<Release?, Error>) -> Void) {
        Task {
            do {
                let r = try await Updater.latest()
                completion(.success(r.map { Release(version: $0.version, url: $0.page) }))
            } catch {
                completion(.failure(error))
            }
        }
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
