import Foundation

/// 認証情報や任意の API を再送せず、録画用の既知の維持 API だけを許可する。
struct PlaybackSession: Equatable {
    let url: URL

    init?(observedURL: URL, server: ServerAddress) {
        guard server.sameOrigin(observedURL),
              var components = URLComponents(url: observedURL, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.fragment == nil else { return nil }
        let pattern = #"^/api/streams/video/[0-9]+/[A-Za-z0-9_-]+/keep-alive$"#
        guard components.percentEncodedPath == components.path,
              components.path.range(of: pattern, options: .regularExpression) != nil,
              let items = components.queryItems, items.count == 1,
              items[0].name == "session_id", let sessionID = items[0].value,
              sessionID.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil else { return nil }
        components.queryItems = [URLQueryItem(name: "session_id", value: sessionID)]
        guard let normalizedURL = components.url else { return nil }
        url = normalizedURL
    }
}

/// PiP 中だけ録画の 10 秒セッション失効を補う。動画データの取得は引き続き WebKit が担当する。
final class PlaybackKeepAlive: NSObject, URLSessionTaskDelegate {
    private var timer: Timer?
    private var activeTask: URLSessionDataTask?
    private var activeRequestID: UUID?
    private var currentSession: PlaybackSession?
    private var isPictureInPictureActive = false
    private lazy var networkSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 5
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        // 維持 API は現行 KonomiTV では認証不要。Web のトークンや Cookie を複製しない。
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    func setSession(_ session: PlaybackSession?) {
        guard currentSession != session else { return }
        activeTask?.cancel()
        activeTask = nil
        activeRequestID = nil
        currentSession = session
        updateTimer()
    }

    func setPictureInPictureActive(_ active: Bool) {
        guard isPictureInPictureActive != active else { return }
        isPictureInPictureActive = active
        updateTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        activeTask?.cancel()
        activeTask = nil
        activeRequestID = nil
        currentSession = nil
        isPictureInPictureActive = false
    }

    private func updateTimer() {
        timer?.invalidate()
        timer = nil
        guard isPictureInPictureActive, currentSession != nil else {
            activeTask?.cancel()
            activeTask = nil
            activeRequestID = nil
            return
        }
        sendKeepAlive()
        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in self?.sendKeepAlive() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func sendKeepAlive() {
        guard activeTask == nil, isPictureInPictureActive, let session = currentSession else { return }
        var request = URLRequest(url: session.url)
        request.httpMethod = "PUT"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let requestID = UUID()
        activeRequestID = requestID
        let task = networkSession.dataTask(with: request) { [weak self] _, response, _ in
            DispatchQueue.main.async {
                guard let self = self, self.activeRequestID == requestID,
                      self.currentSession == session else { return }
                self.activeTask = nil
                self.activeRequestID = nil
                // 終了済み・存在しない対象への再送を止める。成功扱いにして隠さない。
                if let response = response as? HTTPURLResponse,
                   [401, 403, 404, 410, 422].contains(response.statusCode) {
                    self.setSession(nil)
                }
            }
        }
        activeTask = task
        task.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // 検証した維持 URL から別のサーバーや API へのリダイレクトは追従しない。
        completionHandler(nil)
    }
}
