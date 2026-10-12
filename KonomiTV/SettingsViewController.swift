import UIKit

final class SettingsViewController: UIViewController, UITextFieldDelegate {
    private let currentAddress: ServerAddress?
    private let settings: AppSettings
    private let onSave: (ServerAddress) -> Void
    private let scrollView = UIScrollView()
    private let addressField = UITextField()
    private let errorLabel = UILabel()
    private let saveButton = UIButton(type: .system)
    private let historyRows = UIStackView()
    private let gradient = CAGradientLayer()
    private let accent = UIColor(red: 0.67, green: 0.48, blue: 0.99, alpha: 1)

    init(currentAddress: ServerAddress?, settings: AppSettings = .shared, onSave: @escaping (ServerAddress) -> Void) {
        self.currentAddress = currentAddress
        self.settings = settings
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(currentAddress:onSave:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        isModalInPresentation = currentAddress == nil
        view.backgroundColor = UIColor(red: 0.055, green: 0.05, blue: 0.08, alpha: 1)
        gradient.colors = [
            UIColor(red: 0.15, green: 0.08, blue: 0.24, alpha: 1).cgColor,
            UIColor(red: 0.055, green: 0.05, blue: 0.08, alpha: 1).cgColor
        ]
        gradient.locations = [0, 0.7]
        view.layer.insertSublayer(gradient, at: 0)

        if currentAddress != nil {
            title = "サーバー設定"
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .close, target: self, action: #selector(close)
            )
            navigationItem.rightBarButtonItem?.accessibilityLabel = "設定を閉じる"
        }
        buildContent()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        gradient.frame = view.bounds
        if addressField.isFirstResponder {
            let fieldRect = addressField.convert(addressField.bounds, to: scrollView).insetBy(dx: 0, dy: -20)
            scrollView.scrollRectToVisible(fieldRect, animated: false)
        }
    }

    private func buildContent() {
        scrollView.keyboardDismissMode = .interactive
        scrollView.alwaysBounceVertical = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        let content = UIStackView()
        content.axis = .vertical
        content.spacing = 24
        content.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(content)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 28),
            content.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -32),
            content.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -24)
        ])

        let emblemRow = UIView()
        let emblem = UIImageView(image: UIImage(systemName: "play.tv.fill"))
        emblem.tintColor = accent
        emblem.contentMode = .scaleAspectFit
        emblem.translatesAutoresizingMaskIntoConstraints = false
        emblemRow.addSubview(emblem)
        NSLayoutConstraint.activate([
            emblem.heightAnchor.constraint(equalToConstant: 52),
            emblem.widthAnchor.constraint(equalToConstant: 64),
            emblem.topAnchor.constraint(equalTo: emblemRow.topAnchor),
            emblem.bottomAnchor.constraint(equalTo: emblemRow.bottomAnchor),
            emblem.leadingAnchor.constraint(equalTo: emblemRow.leadingAnchor)
        ])
        emblemRow.isAccessibilityElement = false
        content.addArrangedSubview(emblemRow)

        let heading = label(currentAddress == nil ? "KonomiTVに接続" : "接続先を設定", style: .largeTitle, weight: .bold)
        content.addArrangedSubview(heading)
        content.setCustomSpacing(10, after: heading)
        content.addArrangedSubview(label(
            "お使いのKonomiTVサーバーのHTTPS URLを入力してください。アカウントへのログインは接続後に行えます。",
            style: .body, color: .secondaryLabel
        ))

        if currentAddress == nil {
            let benefits = UIStackView(arrangedSubviews: [
                feature(symbol: "arrow.up.left.and.arrow.down.right", title: "全画面で視聴", detail: "iPhoneでも動画を大きく表示"),
                feature(symbol: "pip", title: "PiPでながら視聴", detail: "再生中の動画を小窓で表示")
            ])
            benefits.axis = .vertical
            benefits.spacing = 20
            content.addArrangedSubview(card(containing: benefits))
        }

        let form = UIStackView()
        form.axis = .vertical
        form.spacing = 12
        let fieldLabel = label("サーバーURL", style: .headline, weight: .semibold)
        form.addArrangedSubview(fieldLabel)

        addressField.text = currentAddress?.url.absoluteString
        addressField.placeholder = "https://…"
        addressField.keyboardType = .URL
        addressField.textContentType = .URL
        addressField.autocapitalizationType = .none
        addressField.autocorrectionType = .no
        addressField.spellCheckingType = .no
        addressField.smartDashesType = .no
        addressField.smartQuotesType = .no
        addressField.clearButtonMode = .whileEditing
        addressField.returnKeyType = .go
        addressField.delegate = self
        addressField.font = UIFont.preferredFont(forTextStyle: .body)
        addressField.adjustsFontForContentSizeCategory = true
        addressField.textColor = .label
        addressField.tintColor = accent
        addressField.accessibilityLabel = "KonomiTVサーバーのHTTPS URL"
        addressField.accessibilityIdentifier = "serverURLField"
        addressField.addTarget(self, action: #selector(addressChanged), for: .editingChanged)

        let fieldContainer = UIView()
        fieldContainer.backgroundColor = UIColor.white.withAlphaComponent(0.055)
        fieldContainer.layer.cornerRadius = 14
        fieldContainer.layer.borderWidth = 1
        fieldContainer.layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor
        addressField.translatesAutoresizingMaskIntoConstraints = false
        fieldContainer.addSubview(addressField)
        NSLayoutConstraint.activate([
            addressField.leadingAnchor.constraint(equalTo: fieldContainer.leadingAnchor, constant: 16),
            addressField.trailingAnchor.constraint(equalTo: fieldContainer.trailingAnchor, constant: -12),
            addressField.topAnchor.constraint(equalTo: fieldContainer.topAnchor, constant: 17),
            addressField.bottomAnchor.constraint(equalTo: fieldContainer.bottomAnchor, constant: -17),
            fieldContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 56)
        ])
        form.addArrangedSubview(fieldContainer)

        let example = label("例: https://192-168-1-10.local.konomi.tv:7000/", style: .footnote, color: .secondaryLabel)
        example.accessibilityLabel = "URLの例。https://192-168-1-10.local.konomi.tv:7000/"
        form.addArrangedSubview(example)

        errorLabel.numberOfLines = 0
        errorLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        errorLabel.accessibilityIdentifier = "serverURLError"
        form.addArrangedSubview(errorLabel)
        content.addArrangedSubview(form)

        var configuration = UIButton.Configuration.filled()
        configuration.title = currentAddress == nil ? "接続してはじめる" : "保存して接続"
        configuration.image = UIImage(systemName: "arrow.right")
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 10
        configuration.baseBackgroundColor = accent
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .large
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20)
        saveButton.configuration = configuration
        saveButton.accessibilityIdentifier = "saveServerButton"
        saveButton.addTarget(self, action: #selector(save), for: .touchUpInside)
        content.addArrangedSubview(saveButton)
        updateSaveState()

        let historySection = UIStackView()
        historySection.axis = .vertical
        historySection.spacing = 12
        historySection.addArrangedSubview(label("接続履歴", style: .headline, weight: .semibold))
        historySection.addArrangedSubview(label(
            "タップして接続できます。ピン留めした接続先は上に表示されます。",
            style: .footnote, color: .secondaryLabel
        ))
        historyRows.axis = .vertical
        historyRows.spacing = 12
        historyRows.accessibilityIdentifier = "connectionHistory"
        historySection.addArrangedSubview(historyRows)
        content.addArrangedSubview(historySection)
        refreshHistory()

        let connectionNote = label(
            "このiPhoneから接続できる、有効な証明書のHTTPS URLを使用してください。自宅内のサーバーには同じWi-Fi、外出先からはVPNなどで接続します。",
            style: .footnote, color: .secondaryLabel
        )
        content.addArrangedSubview(connectionNote)
        content.setCustomSpacing(10, after: connectionNote)
        content.addArrangedSubview(label(
            "PiPは対応する動画で利用できます。\nKonomiTV for iOS · iOS 18.3以降",
            style: .caption1, color: .tertiaryLabel
        ))
    }

    private func label(_ text: String, style: UIFont.TextStyle, weight: UIFont.Weight? = nil, color: UIColor = .label) -> UILabel {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.textColor = color
        let preferred = UIFont.preferredFont(forTextStyle: style)
        let standardSize = UIFont.preferredFont(forTextStyle: style, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).pointSize
        label.font = weight.map { UIFontMetrics(forTextStyle: style).scaledFont(for: UIFont.systemFont(ofSize: standardSize, weight: $0)) } ?? preferred
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    private func feature(symbol: String, title: String, detail: String) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = accent
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 28), icon.heightAnchor.constraint(equalToConstant: 28)])
        let text = UIStackView(arrangedSubviews: [
            label(title, style: .subheadline, weight: .semibold),
            label(detail, style: .footnote, color: .secondaryLabel)
        ])
        text.axis = .vertical
        text.spacing = 4
        let row = UIStackView(arrangedSubviews: [icon, text])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 16
        return row
    }

    private func card(containing content: UIView) -> UIView {
        let card = UIView()
        card.backgroundColor = UIColor.white.withAlphaComponent(0.045)
        card.layer.cornerRadius = 20
        card.layer.borderWidth = 1
        card.layer.borderColor = accent.withAlphaComponent(0.13).cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20)
        ])
        return card
    }

    private func refreshHistory() {
        for row in historyRows.arrangedSubviews {
            historyRows.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        let entries = settings.connectionHistory
        guard !entries.isEmpty else {
            historyRows.addArrangedSubview(label(
                "接続に成功したサーバーがここに表示されます。",
                style: .footnote, color: .tertiaryLabel
            ))
            return
        }
        for entry in entries { historyRows.addArrangedSubview(historyCard(entry)) }
    }

    private func historyCard(_ entry: AppSettings.ConnectionHistoryEntry) -> UIView {
        let connect = UIButton(type: .system)
        connect.accessibilityIdentifier = "reconnectServer"
        connect.accessibilityLabel = "\(entry.address.url.absoluteString)に接続"
        connect.addAction(UIAction { [weak self] _ in self?.connect(to: entry.address) }, for: .touchUpInside)

        let title = label(entry.address.url.host ?? "KonomiTVサーバー", style: .subheadline, weight: .semibold)
        let url = label(entry.address.url.absoluteString, style: .footnote, color: .secondaryLabel)
        url.lineBreakMode = .byCharWrapping
        let detail: String
        if entry.address == currentAddress {
            detail = "現在の接続先"
        } else if entry.lastConnectedAt == .distantPast {
            detail = "保存済みの接続先"
        } else {
            detail = "最終接続: " + DateFormatter.localizedString(from: entry.lastConnectedAt, dateStyle: .short, timeStyle: .short)
        }
        let text = UIStackView(arrangedSubviews: [title, url, label(detail, style: .caption1, color: accent)])
        text.axis = .vertical
        text.spacing = 6
        text.isUserInteractionEnabled = false
        text.translatesAutoresizingMaskIntoConstraints = false
        connect.addSubview(text)
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: connect.topAnchor),
            text.bottomAnchor.constraint(equalTo: connect.bottomAnchor),
            text.leadingAnchor.constraint(equalTo: connect.leadingAnchor),
            text.trailingAnchor.constraint(equalTo: connect.trailingAnchor),
            connect.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])

        let pin = historyAction(
            title: entry.isPinned ? "ピン解除" : "ピン留め",
            symbol: entry.isPinned ? "pin.fill" : "pin",
            color: accent
        )
        pin.accessibilityIdentifier = "pinServer"
        pin.accessibilityLabel = entry.isPinned ? "この接続先のピン留めを解除" : "この接続先をピン留め"
        pin.addAction(UIAction { [weak self] _ in
            guard let self = self else { return }
            self.settings.setConnectionPinned(entry.address, isPinned: !entry.isPinned)
            self.refreshHistory()
            UIAccessibility.post(notification: .announcement, argument: entry.isPinned ? "ピン留めを解除しました" : "ピン留めしました")
        }, for: .touchUpInside)

        let delete = historyAction(title: "削除", symbol: "trash", color: .systemRed)
        delete.accessibilityIdentifier = "deleteServerHistory"
        delete.accessibilityLabel = "この接続先を履歴から削除"
        delete.addAction(UIAction { [weak self] _ in self?.confirmDelete(entry.address) }, for: .touchUpInside)
        let controls = UIStackView(arrangedSubviews: [pin, delete])
        controls.axis = .horizontal
        controls.spacing = 8
        controls.distribution = .fillEqually

        let row = UIStackView(arrangedSubviews: [connect, controls])
        row.axis = .vertical
        row.spacing = 14
        return card(containing: row)
    }

    private func historyAction(title: String, symbol: String, color: UIColor) -> UIButton {
        var configuration = UIButton.Configuration.tinted()
        configuration.title = title
        configuration.image = UIImage(systemName: symbol)
        configuration.imagePadding = 6
        configuration.titleLineBreakMode = .byWordWrapping
        configuration.baseForegroundColor = color
        configuration.baseBackgroundColor = color.withAlphaComponent(0.12)
        configuration.cornerStyle = .medium
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 8)
        let button = UIButton(configuration: configuration)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return button
    }

    private func confirmDelete(_ address: ServerAddress) {
        let confirmation = UIAlertController(
            title: "履歴から削除しますか？",
            message: "\(address.url.absoluteString)\n\n接続履歴からこのURLを削除します。現在の接続はそのまま続きます。",
            preferredStyle: .alert
        )
        confirmation.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        confirmation.addAction(UIAlertAction(title: "削除", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            self.settings.deleteConnection(address)
            self.refreshHistory()
            UIAccessibility.post(notification: .announcement, argument: "接続履歴から削除しました")
        })
        present(confirmation, animated: true)
    }

    @objc private func addressChanged() {
        errorLabel.isHidden = true
        updateSaveState()
    }

    private func updateSaveState() {
        saveButton.isEnabled = !(addressField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        saveButton.alpha = saveButton.isEnabled ? 1 : 0.55
    }

    @objc private func save() {
        let address: ServerAddress
        do {
            address = try ServerAddress(input: addressField.text ?? "")
        } catch {
            errorLabel.text = error.localizedDescription
            errorLabel.isHidden = false
            UIAccessibility.post(notification: .announcement, argument: error.localizedDescription)
            return
        }
        connect(to: address)
    }

    private func connect(to address: ServerAddress) {
        addressField.text = address.url.absoluteString
        errorLabel.isHidden = true
        updateSaveState()
        view.endEditing(true)
        guard let currentAddress, currentAddress != address else {
            onSave(address)
            return
        }
        let confirmation = UIAlertController(
            title: "接続先を変更しますか？",
            message: "\(currentAddress.url.absoluteString)\n↓\n\(address.url.absoluteString)\n\n再生中の動画は停止します。",
            preferredStyle: .alert
        )
        confirmation.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        confirmation.addAction(UIAlertAction(title: "変更して接続", style: .default) { [weak self] _ in
            self?.onSave(address)
        })
        present(confirmation, animated: true)
    }

    @objc private func close() {
        guard currentAddress != nil else { return }
        if presentingViewController != nil || navigationController?.presentingViewController != nil {
            dismiss(animated: true)
        } else {
            navigationController?.popViewController(animated: true)
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if saveButton.isEnabled { save() }
        return true
    }
}
