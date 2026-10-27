import CoachKit
import Foundation

/// The only place the coach talks to the network. `CoachService` (in CoachKit) decides whether anything is sent; this
/// just carries the request. Reads two Info.plist values that are absent by default: `CoachEnabled` (Bool) and
/// `CoachBaseURL` (String). With either missing or empty the config is off and no request is ever built.
struct URLSessionCoachTransport: CoachTransport {
  let baseURL: URL
  var session: URLSession = .shared

  func send(_ request: CoachHTTPRequest) async throws -> CoachHTTPResponse {
    guard let url = URL(string: request.path, relativeTo: baseURL)?.absoluteURL else { throw URLError(.badURL) }
    var r = URLRequest(url: url, timeoutInterval: 20)
    r.httpMethod = request.method
    if let body = request.body {
      r.httpBody = body
      r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    if let bearer = request.bearer { r.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
    let (data, response) = try await session.data(for: r)
    return CoachHTTPResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
  }
}

/// A transport that never sends; used when the coach is off so there is no URL to build.
struct NoCoachTransport: CoachTransport {
  func send(_ request: CoachHTTPRequest) async throws -> CoachHTTPResponse { throw URLError(.notConnectedToInternet) }
}

final class DefaultsCoachStore: CoachStore {
  private let defaults: UserDefaults
  init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }
  func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
  func set(_ data: Data?, forKey key: String) {
    if let data { defaults.set(data, forKey: key) } else { defaults.removeObject(forKey: key) }
  }
}

@MainActor
enum CoachBuild {
  static func config(_ bundle: Bundle = .main) -> CoachConfig {
    CoachConfig(enabled: bundle.object(forInfoDictionaryKey: "CoachEnabled") as? Bool ?? false,
                baseURL: bundle.object(forInfoDictionaryKey: "CoachBaseURL") as? String ?? "")
  }

  static func makeService(_ bundle: Bundle = .main) -> CoachService {
    let config = config(bundle)
    let transport: CoachTransport = config.isAvailable ? (URL(string: config.baseURL).map { URLSessionCoachTransport(baseURL: $0) } ?? NoCoachTransport()) : NoCoachTransport()
    return CoachService(config: config, transport: transport, store: DefaultsCoachStore())
  }
}
