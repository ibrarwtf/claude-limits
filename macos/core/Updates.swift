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
