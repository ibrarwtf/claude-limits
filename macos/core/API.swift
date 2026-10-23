import Foundation

let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
let oauthBeta = "oauth-2025-04-20"

func fetchUsage(taskHandle: ((URLSessionDataTask) -> Void)? = nil,
                completion: @escaping (Result<UsageResponse, AppError>) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
        let token: String
        do { token = try loadAccessToken() }
        catch let e as AppError { completion(.failure(e)); return }
        catch { completion(.failure(.parseFailed(error.localizedDescription))); return }

        var req = URLRequest(url: usageURL)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(oauthBeta, forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 10

        let task = URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err {
                let code = (err as NSError).code
                if code == NSURLErrorCancelled { return }
                if code == NSURLErrorTimedOut { completion(.failure(.requestTimeout)); return }
                if code == NSURLErrorNotConnectedToInternet
                    || code == NSURLErrorCannotFindHost
                    || code == NSURLErrorCannotConnectToHost
                    || code == NSURLErrorNetworkConnectionLost {
                    completion(.failure(.networkUnavailable)); return
                }
                completion(.failure(.parseFailed(err.localizedDescription))); return
            }
            let body = String(data: data ?? Data(), encoding: .utf8) ?? ""
            if let http = resp as? HTTPURLResponse {
                var retry: TimeInterval? = nil
                if let s = (http.allHeaderFields["Retry-After"] as? String) ?? (http.allHeaderFields["retry-after"] as? String) {
                    retry = Double(s.trimmingCharacters(in: .whitespaces))
                }
                if let e = statusError(http.statusCode, retry, body) { completion(.failure(e)); return }
            }
            guard let data = data else {
                completion(.failure(.parseFailed("empty response"))); return
            }
            do {
                let u = try JSONDecoder().decode(UsageResponse.self, from: data)
                completion(.success(u))
            } catch {
                completion(.failure(.parseFailed(error.localizedDescription)))
            }
        }
        DispatchQueue.main.async { taskHandle?(task) }
        task.resume()
    }
}
