import Foundation

let latestReleaseURL = URL(string: "https://api.github.com/repos/ibrarwtf/claude-limits/releases/latest")!

struct GitHubRelease: Codable {
    let tagName: String
    enum CodingKeys: String, CodingKey { case tagName = "tag_name" }
}

func fetchLatestRelease(completion: @escaping (Result<GitHubRelease, Error>) -> Void) {
    var req = URLRequest(url: latestReleaseURL)
    req.httpMethod = "GET"
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    req.timeoutInterval = 10
    URLSession.shared.dataTask(with: req) { data, _, err in
        if let err = err { completion(.failure(err)); return }
        guard let data = data else {
            completion(.failure(NSError(domain: "claude-limits", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "empty response"])))
            return
        }
        do {
            let r = try JSONDecoder().decode(GitHubRelease.self, from: data)
            completion(.success(r))
        } catch {
            completion(.failure(error))
        }
    }.resume()
}

/// Compare two semver-ish strings ("v0.1.4", "0.1.10"). Strips a leading "v",
/// splits on ".", compares numerically. Missing components count as 0.
func isNewerVersion(_ latest: String, than current: String) -> Bool {
    func parse(_ s: String) -> [Int] {
        let stripped = s.hasPrefix("v") ? String(s.dropFirst()) : s
        return stripped.split(separator: ".").compactMap { Int($0) }
    }
    let l = parse(latest), c = parse(current)
    for i in 0..<max(l.count, c.count) {
        let a = i < l.count ? l[i] : 0
        let b = i < c.count ? c[i] : 0
        if a > b { return true }
        if a < b { return false }
    }
    return false
}
