import Foundation
import WebKit

protocol WebBridgeDelegate: AnyObject {
    func bridgeDidBecomeReady()
    func bridgePictureInPictureChanged(isActive: Bool)
    func bridgePlaybackChanged(isPlaying: Bool)
    func bridgeRecordingSessionChanged(url: URL?)
    func bridgeReportedError(_ message: String)
    func bridgeRequestedSettings()
    func bridgeRequestedReload()
    func bridgeRequestedLandscapeToggle()
    func bridgeRequestedLandscapeExit()
}

/// 登録先の Web UI・PiP・録画セッションを連携する。受け付ける操作は固定する。
final class WebBridge: NSObject, WKScriptMessageHandler {
    static let handlerName = "konomiNative"
    weak var delegate: WebBridgeDelegate?
    private var address: ServerAddress?

    func configure(_ controller: WKUserContentController, address: ServerAddress) throws {
        guard let path = Bundle.main.url(forResource: "MediaBridge", withExtension: "js"),
              let template = try? String(contentsOf: path, encoding: .utf8) else {
            throw BridgeError.missingResource
        }
        let originData = try JSONSerialization.data(withJSONObject: address.origin, options: .fragmentsAllowed)
        guard let quotedOrigin = String(data: originData, encoding: .utf8) else {
            throw BridgeError.missingResource
        }
        self.address = address
        controller.removeScriptMessageHandler(forName: Self.handlerName)
        controller.removeAllUserScripts()
        // このアプリ専用の controller。第三者フレームからのメッセージは下で拒否する。
        controller.add(self, name: Self.handlerName)
        let script = template.replacingOccurrences(of: "__KONOMI_ORIGIN__", with: quotedOrigin)
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == Self.handlerName,
              message.frameInfo.isMainFrame,
              let frameURL = message.frameInfo.request.url,
              let address = address, address.sameOrigin(frameURL),
              let payload = message.body as? [String: Any],
              let event = payload["event"] as? String else { return }

        switch event {
        case "ready":
            delegate?.bridgeDidBecomeReady()
        case "settings":
            delegate?.bridgeRequestedSettings()
        case "reload":
            delegate?.bridgeRequestedReload()
        case "landscape-toggle":
            delegate?.bridgeRequestedLandscapeToggle()
        case "landscape-exit":
            delegate?.bridgeRequestedLandscapeExit()
        case "pip":
            if let active = payload["active"] as? Bool {
                delegate?.bridgePictureInPictureChanged(isActive: active)
            }
        case "playback":
            if let playing = payload["playing"] as? Bool {
                delegate?.bridgePlaybackChanged(isPlaying: playing)
            }
        case "session":
            guard let raw = payload["url"] as? String else {
                delegate?.bridgeRecordingSessionChanged(url: nil)
                return
            }
            // URL の文字列長を制限し、実際の宛先は PlaybackSession でも再検証する。
            guard raw.count < 2048, let url = URL(string: raw), address.sameOrigin(url) else { return }
            delegate?.bridgeRecordingSessionChanged(url: url)
        case "error":
            if let text = payload["message"] as? String {
                delegate?.bridgeReportedError(String(text.prefix(240)))
            }
        case "media-diagnostic":
            #if DEBUG
            let keys = ["kind", "paused", "ended", "readyState", "time", "hidden", "mode", "bufferedEnd", "errorCode"]
            let state = payload.filter { keys.contains($0.key) }
            if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                print("[Konomios media] \(text)")
            }
            #endif
        case "layout-diagnostic":
            #if DEBUG
            let keys = ["width", "height", "fullscreen", "landscapeLocked", "watchWidth", "watchHeight"]
            let state = payload.filter { keys.contains($0.key) }
            if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                print("[Konomios layout] \(text)")
            }
            #endif
        default:
            break
        }
    }

    enum BridgeError: LocalizedError {
        case missingResource
        var errorDescription: String? { "プレイヤーの連携ファイルを読み込めませんでした。" }
    }
}
