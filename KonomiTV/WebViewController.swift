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
    private var progressObservation: NSKeyValueObservation?
    private var landscapeLocked = false
    private var inlineOrientation: UIInterfaceOrientation?
    private var orientationRequestGeneration = 0
    private var pipActive = false
    private var navigationResponseSucceeded = false
    private var navigationResponseStatus: Int?
    private enum NativeAction { case settings, reload }
    private let progress = UIProgressView(progressViewStyle: .bar)
    private let errorLabel = UILabel()
    private let errorPanel = UIStackView()
    private let webContainer = UIView()
    private let emptyLabel = UILabel()
    private let accent = UIColor(red: 0.64, green: 0.45, blue: 0.96, alpha: 1)

    override var prefersStatusBarHidden: Bool { landscapeLocked }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        if landscapeLocked { return .landscape }
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
        refreshLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        webView?.frame = webContainer.bounds
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.refreshLayout() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.07, green: 0.065, blue: 0.10, alpha: 1)
        bridge.delegate = self
        configureAudioSession()
        buildLayout()
        buildWebView()
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
        // Keep the top and sides safe while drawing underneath the home indicator.
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
        configuration.preferences.isElementFullscreenEnabled = false
        // KonomiTV owns autoplay and manual video PiP.
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
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.frame = webContainer.bounds
        webContainer.insertSubview(webView, belowSubview: emptyLabel)
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
        setLandscapeLocked(false)
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

    private func setLandscapeLocked(_ locked: Bool) {
        guard locked != landscapeLocked else { return }
        let previousLocked = landscapeLocked
        let previousOrientation = inlineOrientation
        if locked { inlineOrientation = view.window?.windowScene?.interfaceOrientation ?? .portrait }
        let returnOrientation = inlineOrientation
        landscapeLocked = locked
        if !locked { inlineOrientation = nil }
        orientationRequestGeneration += 1
        let generation = orientationRequestGeneration
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfSupportedInterfaceOrientations()
        synchronizeLandscapeState()
        guard let scene = view.window?.windowScene else { return }
        let mask: UIInterfaceOrientationMask
        if locked { mask = .landscape }
        else {
            switch returnOrientation {
            case .landscapeLeft: mask = .landscapeLeft
            case .landscapeRight: mask = .landscapeRight
            case .portraitUpsideDown where UIDevice.current.userInterfaceIdiom == .pad: mask = .portraitUpsideDown
            default: mask = .portrait
            }
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { [weak self] error in
            guard let self = self, self.orientationRequestGeneration == generation else { return }
            self.landscapeLocked = previousLocked
            self.inlineOrientation = previousOrientation
            self.setNeedsStatusBarAppearanceUpdate()
            self.setNeedsUpdateOfSupportedInterfaceOrientations()
            self.synchronizeLandscapeState()
            self.displayError("画面の向きを変更できませんでした。もう一度お試しください。")
            #if DEBUG
            print("[Konomios orientation] \(error.localizedDescription)")
            #endif
        }
    }

    private func synchronizeLandscapeState() {
        webView?.callAsyncJavaScript("window.KonomiTVNative?.setLandscapeLocked(locked)",
                                    arguments: ["locked": landscapeLocked], in: nil, in: .page, completionHandler: nil)
    }

    func refreshLayout() {
        guard isViewLoaded else { return }
        view.setNeedsLayout()
        view.layoutIfNeeded()
        webView?.frame = webContainer.bounds
    }

    private func requestNativeAction(_ action: NativeAction) {
        guard !pipActive else {
            displayError("この操作を行うには、PiP を閉じてください。")
            return
        }
        setLandscapeLocked(false)
        switch action {
        case .settings: showSettings()
        case .reload: reloadPage()
        }
    }

    func becomeActive() {
        guard isViewLoaded else { return }
        refreshMediaState()
        refreshLayout()
    }

    func refreshMediaState() {
        guard isViewLoaded else { return }
        webView.evaluateJavaScript("window.KonomiTVNative?.refresh()", completionHandler: nil)
    }

    private func configureAudioSession() {
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .moviePlayback)
            // WebKit activates its own media session. Activating the app's session after
            // a video starts competes with it and immediately pauses the live stream.
            #if DEBUG
            print("[Konomios audio] configured before WebView creation; activation owned by WebKit")
            #endif
        } catch {
            displayError("音声の再生設定を有効にできませんでした。")
        }
    }

    private func displayError(_ message: String) {
        errorLabel.text = message
        errorPanel.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    @objc private func hideError() { errorPanel.isHidden = true }

    func bridgeDidBecomeReady() { synchronizeLandscapeState() }
    func bridgeRequestedLandscapeToggle() { setLandscapeLocked(!landscapeLocked) }
    func bridgeRequestedLandscapeExit() { setLandscapeLocked(false) }
    func bridgeRequestedSettings() { requestNativeAction(.settings) }
    func bridgeRequestedReload() { requestNativeAction(.reload) }

    func bridgePictureInPictureChanged(isActive: Bool) {
        pipActive = isActive
        keepAlive.setPictureInPictureActive(isActive)
    }

    func bridgePlaybackChanged(isPlaying: Bool) {
        // WebKit owns audio activation and interruptions; never activate a competing session.
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
        synchronizeLandscapeState()
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
        displayError("視聴画面が終了しました。再読み込みして再開してください。")
    }
}
