import UIKit
import WebKit
import AVFAudio

/// 設定の変更時以外は同じ WKWebView とプレイヤーを保持する。
final class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WebBridgeDelegate {
    private let settings = AppSettings.shared
    private let bridge = WebBridge()
    private let keepAlive = PlaybackKeepAlive()
    private var address: ServerAddress?
    private var webView: WKWebView!
    private var fullscreenObservation: NSKeyValueObservation?
    private var progressObservation: NSKeyValueObservation?
    private var fullscreen = false
    private var pipActive = false
    private var audioActivated = false
    private let header = UIStackView()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let progress = UIProgressView(progressViewStyle: .bar)
    private let errorLabel = UILabel()
    private let webContainer = UIView()
    private let emptyLabel = UILabel()
    private let accent = UIColor(red: 0.64, green: 0.45, blue: 0.96, alpha: 1)

    override var prefersStatusBarHidden: Bool { fullscreen }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .pad { return .all }
        return fullscreen ? .landscape : .allButUpsideDown
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.07, green: 0.065, blue: 0.10, alpha: 1)
        bridge.delegate = self
        buildLayout()
        buildWebView()
        NotificationCenter.default.addObserver(self, selector: #selector(audioInterrupted(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
        if let saved = settings.serverAddress {
            openServer(saved)
        } else {
            emptyLabel.text = "KonomiTV を、いつものサーバーで。\n右上の設定から接続先を登録してください。"
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if address == nil, presentedViewController == nil { showSettings() }
    }

    private func buildLayout() {
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 12
        header.isLayoutMarginsRelativeArrangement = true
        header.layoutMargins = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 12)
        let icon = UIImageView(image: UIImage(systemName: "tv"))
        icon.tintColor = accent
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        let labels = UIStackView(arrangedSubviews: [titleLabel, statusLabel])
        labels.axis = .vertical
        labels.spacing = 2
        titleLabel.text = "Konomios"
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabel
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.text = "KonomiTV の接続先を設定"
        let reload = UIButton(type: .system)
        reload.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
        reload.accessibilityLabel = "再読み込み"
        reload.addTarget(self, action: #selector(reloadPage), for: .touchUpInside)
        let gear = UIButton(type: .system)
        gear.setImage(UIImage(systemName: "gearshape"), for: .normal)
        gear.accessibilityLabel = "接続先の設定"
        gear.addTarget(self, action: #selector(showSettings), for: .touchUpInside)
        [reload, gear].forEach { button in
            button.tintColor = .label
            button.widthAnchor.constraint(equalToConstant: 40).isActive = true
            button.heightAnchor.constraint(equalToConstant: 40).isActive = true
        }
        [icon, labels, reload, gear].forEach(header.addArrangedSubview)
        progress.progressTintColor = accent
        progress.trackTintColor = .clear
        errorLabel.font = .systemFont(ofSize: 13)
        errorLabel.textColor = UIColor.systemOrange
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true
        errorLabel.accessibilityTraits = .staticText
        let errorRow = UIStackView(arrangedSubviews: [errorLabel])
        errorRow.isLayoutMarginsRelativeArrangement = true
        errorRow.layoutMargins = UIEdgeInsets(top: 0, left: 16, bottom: 8, right: 16)
        let stack = UIStackView(arrangedSubviews: [header, progress, errorRow, webContainer])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2)
        ])
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.font = .systemFont(ofSize: 17, weight: .medium)
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        webContainer.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: webContainer.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: webContainer.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: webContainer.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: webContainer.trailingAnchor, constant: -24)
        ])
    }

    private func buildWebView() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.preferences.isElementFullscreenEnabled = true
        // 視聴画面の自動再生を許可。PiP は引き続きユーザーのタップから要求する。
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.applicationNameForUserAgent = "Konomios/0.1.0"
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = view.backgroundColor
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsBackForwardNavigationGestures = true
        #if DEBUG
        webView.isInspectable = true
        #endif
        webView.translatesAutoresizingMaskIntoConstraints = false
        webContainer.insertSubview(webView, belowSubview: emptyLabel)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: webContainer.topAnchor),
            webView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor)
        ])
        fullscreenObservation = webView.observe(\.fullscreenState, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateFullscreenState() }
        }
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            DispatchQueue.main.async {
                self?.progress.progress = Float(webView.estimatedProgress)
                self?.progress.isHidden = webView.estimatedProgress >= 1
            }
        }
    }

    private func openServer(_ server: ServerAddress) {
        // 接続先変更は明示的な操作。PiP を閉じてから読み込み先を切り替える。
        keepAlive.stop()
        pipActive = false
        address = server
        settings.serverAddress = server
        do {
            try bridge.configure(webView.configuration.userContentController, address: server)
            errorLabel.isHidden = true
            emptyLabel.isHidden = true
            statusLabel.text = "接続しています…"
            webView.load(URLRequest(url: server.url))
        } catch {
            displayError(error.localizedDescription)
        }
    }

    @objc private func showSettings() {
        guard !pipActive else {
            displayError("接続先を変更するには、PiP を閉じてください。")
            return
        }
        guard presentedViewController == nil else { return }
        let screen = SettingsViewController(currentAddress: address) { [weak self] server in
            // dismiss の viewDidAppear より前に設定を反映し、初回設定の再表示を防ぐ。
            self?.openServer(server)
            self?.dismiss(animated: true)
        }
        let navigation = UINavigationController(rootViewController: screen)
        navigation.modalPresentationStyle = .pageSheet
        navigation.isModalInPresentation = address == nil
        present(navigation, animated: true)
    }

    @objc private func reloadPage() {
        guard !pipActive else {
            displayError("再読み込みするには、PiP を閉じてください。")
            return
        }
        guard let address = address else { showSettings(); return }
        let alert = UIAlertController(title: "再読み込みしますか？",
                                      message: "視聴中の動画は一度停止します。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        alert.addAction(UIAlertAction(title: "再読み込み", style: .default) { [weak self] _ in
            self?.openServer(address)
        })
        present(alert, animated: true)
    }

    private func updateFullscreenState() {
        fullscreen = webView.fullscreenState == .inFullscreen || webView.fullscreenState == .enteringFullscreen
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfSupportedInterfaceOrientations()
        if let scene = view.window?.windowScene, UIDevice.current.userInterfaceIdiom == .phone {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: fullscreen ? .landscape : .allButUpsideDown))
        }
    }

    func refreshMediaState() {
        guard isViewLoaded else { return }
        webView.evaluateJavaScript("window.KonomiTVNative?.refresh()", completionHandler: nil)
    }

    private func activateAudio() {
        guard !audioActivated else { return }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .moviePlayback)
            try audio.setActive(true)
            audioActivated = true
        } catch {
            displayError("音声の再生設定を有効にできませんでした。")
        }
    }

    @objc private func audioInterrupted(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            audioActivated = false
        } else {
            // 電話後など、OS が再開を許可した場合だけ音声セッションを復帰させる。
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            if AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume) { activateAudio() }
        }
    }

    private func displayError(_ message: String) {
        errorLabel.text = message
        errorLabel.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    func bridgeDidBecomeReady() {
        statusLabel.text = address?.url.host ?? "接続済み"
    }

    func bridgePictureInPictureChanged(isActive: Bool) {
        pipActive = isActive
        keepAlive.setPictureInPictureActive(isActive)
        if isActive { activateAudio() }
        statusLabel.text = isActive ? "PiP で再生中" : address?.url.host
    }

    func bridgePlaybackChanged(isPlaying: Bool) {
        if isPlaying { activateAudio() }
        // 一時停止中も PiP の録画セッションは維持する。
    }

    func bridgeRecordingSessionChanged(url: URL?) {
        guard let address = address else { return }
        keepAlive.setSession(url.flatMap { PlaybackSession(observedURL: $0, server: address) })
    }

    func bridgeReportedError(_ message: String) { displayError(message) }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let address = address else {
            decisionHandler(.cancel)
            return
        }
        // iframe 内の通信・遷移は WebKit の通常の同一生成元ポリシーに従う。bridge は main frame 限定。
        if navigationAction.targetFrame?.isMainFrame == false {
            decisionHandler(.allow)
        } else if address.containsNavigation(url) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            if navigationAction.navigationType == .linkActivated,
               ["https", "http", "mailto", "tel"].contains(url.scheme?.lowercased() ?? "") {
                UIApplication.shared.open(url)
            }
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil, let url = navigationAction.request.url else { return nil }
        if address?.containsNavigation(url) == true {
            webView.load(navigationAction.request)
        } else if ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            UIApplication.shared.open(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        statusLabel.text = address?.url.host
        refreshMediaState()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showNavigationError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showNavigationError(error)
    }

    private func showNavigationError(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        statusLabel.text = "接続できませんでした"
        displayError("サーバーの起動状態、URL、ネットワークを確認してください。\n\(error.localizedDescription)")
        progress.isHidden = true
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        keepAlive.stop()
        pipActive = false
        displayError("視聴画面が終了しました。再読み込みして再開してください。")
    }
}
