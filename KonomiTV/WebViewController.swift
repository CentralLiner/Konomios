import UIKit
import WebKit
import AVFAudio

/// 設定の変更時以外は同じ WKWebView とプレイヤーを保持する。
final class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WebBridgeDelegate {
    private let settings: AppSettings
    private let bridge = WebBridge()
    private let keepAlive = PlaybackKeepAlive()
    private var address: ServerAddress?
    private var webView: WKWebView!
    private var fullscreenObservation: NSKeyValueObservation?
    private var progressObservation: NSKeyValueObservation?
    private var fullscreen = false
    private var pipActive = false
    private var audioActivated = false
    private var navigationResponseSucceeded = false
    private var navigationResponseStatus: Int?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var backgroundTaskTimeout: DispatchWorkItem?
    private var pendingNativeAction: NativeAction?
    private enum NativeAction { case settings, reload }
    private let progress = UIProgressView(progressViewStyle: .bar)
    private let errorLabel = UILabel()
    private let errorPanel = UIStackView()
    private let webContainer = UIView()
    private let emptyLabel = UILabel()
    private let accent = UIColor(red: 0.64, green: 0.45, blue: 0.96, alpha: 1)

    override var prefersStatusBarHidden: Bool { fullscreen }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .pad { return .all }
        return .allButUpsideDown
    }

    init(settings: AppSettings = .shared) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        restoreInlineLayoutIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // WebKit owns the frame while the same WebView is in its fullscreen window.
        if webView?.superview === webContainer, webView.fullscreenState == .notInFullscreen {
            webView.frame = webContainer.bounds
        }
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
            emptyLabel.text = "KonomiTV を、いつものサーバーで。\nタップして接続先を登録してください。"
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if address == nil, presentedViewController == nil { showSettings() }
    }

    private func buildLayout() {
        // Give the browser a definite height even while WebKit swaps it for a fullscreen placeholder.
        // A vertical UIStackView would distribute the vacated space to the old native header.
        webContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webContainer)
        NSLayoutConstraint.activate([
            webContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            webContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.font = .systemFont(ofSize: 17, weight: .medium)
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.isUserInteractionEnabled = true
        emptyLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(showSettings)))
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        webContainer.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: webContainer.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: webContainer.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: webContainer.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: webContainer.trailingAnchor, constant: -24)
        ])
        progress.progressTintColor = accent
        progress.trackTintColor = .clear
        progress.isHidden = true
        progress.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progress)
        NSLayoutConstraint.activate([
            progress.topAnchor.constraint(equalTo: webContainer.topAnchor),
            progress.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2)
        ])

        // Only failed connections need native recovery controls: there is no usable web UI then.
        errorLabel.font = .systemFont(ofSize: 13)
        errorLabel.textColor = .systemOrange
        errorLabel.numberOfLines = 0
        errorLabel.accessibilityTraits = .staticText
        let actions = UIStackView()
        actions.axis = .horizontal
        actions.spacing = 12
        for (title, selector) in [("接続先の設定", #selector(showSettings)),
                                  ("再読み込み", #selector(reloadPage)),
                                  ("閉じる", #selector(hideError))] {
            let button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            button.addTarget(self, action: selector, for: .touchUpInside)
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            actions.addArrangedSubview(button)
        }
        errorPanel.axis = .vertical
        errorPanel.spacing = 8
        errorPanel.isLayoutMarginsRelativeArrangement = true
        errorPanel.layoutMargins = UIEdgeInsets(top: 12, left: 16, bottom: 4, right: 16)
        errorPanel.backgroundColor = UIColor(red: 0.12, green: 0.10, blue: 0.16, alpha: 0.98)
        errorPanel.layer.cornerRadius = 12
        errorPanel.addArrangedSubview(errorLabel)
        errorPanel.addArrangedSubview(actions)
        errorPanel.isHidden = true
        errorPanel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(errorPanel)
        NSLayoutConstraint.activate([
            errorPanel.topAnchor.constraint(equalTo: webContainer.topAnchor, constant: 12),
            errorPanel.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor, constant: 12),
            errorPanel.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor, constant: -12)
        ])
    }

    private func buildWebView() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.preferences.isElementFullscreenEnabled = true
        // Allow autoplay; background PiP uses WebKit's video presentation-mode API.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.applicationNameForUserAgent = "Konomios/0.2.0"
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
        // WebKit transfers WKWebView out of this hierarchy for Element Fullscreen.
        // Its placeholder copies frame/autoresizingMask, not our external Auto Layout constraints.
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.frame = webContainer.bounds
        webContainer.insertSubview(webView, belowSubview: emptyLabel)
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
        finishBackgroundTask()
        pendingNativeAction = nil
        address = server
        settings.serverAddress = server
        navigationResponseSucceeded = false
        navigationResponseStatus = nil
        do {
            try bridge.configure(webView.configuration.userContentController, address: server)
            hideError()
            emptyLabel.isHidden = true
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
        let screen = SettingsViewController(currentAddress: address, settings: settings) { [weak self] server in
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
        let state = webView.fullscreenState
        fullscreen = state != .notInFullscreen
        setNeedsStatusBarAppearanceUpdate()
        // Let the device and WebKit choose orientation; forcing a geometry update during the
        // fullscreen transfer races the presentation and can leave a blank player.
        if state == .notInFullscreen {
            restoreInlineLayoutIfNeeded()
            DispatchQueue.main.async { [weak self] in
                self?.restoreInlineLayoutIfNeeded()
                self?.performPendingNativeAction()
            }
        }
    }

    private func restoreInlineLayoutIfNeeded() {
        guard isViewLoaded, let webView = webView, webView.fullscreenState == .notInFullscreen else { return }
        if webView.superview !== webContainer {
            webView.removeFromSuperview()
            webContainer.insertSubview(webView, belowSubview: emptyLabel)
        }
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.frame = webContainer.bounds
        webContainer.setNeedsLayout()
    }

    private func requestNativeAction(_ action: NativeAction) {
        guard !pipActive else {
            displayError("この操作を行うには、PiP を閉じてください。")
            return
        }
        pendingNativeAction = action
        if webView.fullscreenState != .notInFullscreen {
            // Keep KonomiTV's fullscreenchange handler / player state in sync.
            webView.callAsyncJavaScript("""
                const exit = document.exitFullscreen || document.webkitExitFullscreen;
                if (!exit) return false;
                await exit.call(document);
                return true;
                """, arguments: [:], in: nil, in: .page) { [weak self] result in
                switch result {
                case .success(let value) where (value as? Bool) == true:
                    self?.performPendingNativeAction()
                default:
                    self?.pendingNativeAction = nil
                    self?.displayError("全画面を解除してから、もう一度お試しください。")
                }
            }
        } else {
            performPendingNativeAction()
        }
    }

    private func performPendingNativeAction(attempt: Int = 0) {
        guard pendingNativeAction != nil, webView.fullscreenState == .notInFullscreen else { return }
        // Fullscreen's UIKit presentation may finish after the observable state changes.
        if presentedViewController != nil {
            if attempt < 10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.performPendingNativeAction(attempt: attempt + 1)
                }
            } else { pendingNativeAction = nil }
            return
        }
        let action = pendingNativeAction
        pendingNativeAction = nil
        switch action {
        case .settings: showSettings()
        case .reload: reloadPage()
        case .none: break
        }
    }

    func prepareForBackground() {
        guard isViewLoaded, address != nil else { return }
        webView.evaluateJavaScript("window.KonomiTVNative?.prepareForBackground()", completionHandler: nil)
    }

    func enterBackground() {
        guard isViewLoaded, address != nil, !pipActive else { return }
        beginBackgroundTask()
        webView.evaluateJavaScript("window.KonomiTVNative?.enterPictureInPictureForBackground()") { [weak self] result, _ in
            if (result as? Bool) != true { self?.finishBackgroundTask() }
        }
    }

    func becomeActive() {
        finishBackgroundTask()
        guard isViewLoaded else { return }
        webView.evaluateJavaScript("window.KonomiTVNative?.didBecomeActive()", completionHandler: nil)
        refreshMediaState()
        restoreInlineLayoutIfNeeded()
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Start video PiP") { [weak self] in
            self?.finishBackgroundTask()
        }
        let timeout = DispatchWorkItem { [weak self] in self?.finishBackgroundTask() }
        backgroundTaskTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
    }

    private func finishBackgroundTask() {
        backgroundTaskTimeout?.cancel()
        backgroundTaskTimeout = nil
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
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
        errorPanel.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    @objc private func hideError() { errorPanel.isHidden = true }

    func bridgeDidBecomeReady() {}
    func bridgeRequestedSettings() { requestNativeAction(.settings) }
    func bridgeRequestedReload() { requestNativeAction(.reload) }

    func bridgePictureInPictureChanged(isActive: Bool) {
        pipActive = isActive
        keepAlive.setPictureInPictureActive(isActive)
        if isActive { activateAudio(); finishBackgroundTask() }
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

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationResponseSucceeded = false
        navigationResponseStatus = nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame {
            navigationResponseStatus = (navigationResponse.response as? HTTPURLResponse)?.statusCode
            navigationResponseSucceeded = navigationResponseStatus.map { (200..<400).contains($0) } ?? false
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if navigationResponseSucceeded, let address = address, let url = webView.url, address.containsNavigation(url) {
            settings.recordConnection(address)
        }
        if navigationResponseSucceeded {
            hideError()
        } else {
            let status = navigationResponseStatus.map { "（HTTP \($0)）" } ?? ""
            displayError("サーバーの画面を読み込めませんでした\(status)。接続先の URL とサーバーの状態を確認してください。")
        }
        refreshMediaState()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // document の交換で旧ページの終了イベントが失われても、操作抑止を残さない。
        keepAlive.stop()
        pipActive = false
        finishBackgroundTask()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showNavigationError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showNavigationError(error)
    }

    private func showNavigationError(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        displayError("サーバーの起動状態、URL、ネットワークを確認してください。\n\(error.localizedDescription)")
        progress.isHidden = true
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        keepAlive.stop()
        pipActive = false
        finishBackgroundTask()
        displayError("視聴画面が終了しました。再読み込みして再開してください。")
    }
}
