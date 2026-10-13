# Konomios

KonomiTV の既存 Web UI を利用する、iPhone・iPad 用の非公式クライアントです。Swift と WKWebView の公開 API で横画面表示と動画の手動 Picture-in-Picture（PiP）を提供します。インストールには **AltStore Classic** を使います。

## 必要なもの

- iOS / iPadOS 18.3 以降の端末
- 起動済みの [KonomiTV](https://github.com/tsukumijima/KonomiTV) サーバーと、その HTTPS URL
- AltStore Classic を導入した端末。通常の導入手順では、Mac または Windows の AltServer を使用します

KonomiTV サーバー、チューナー、録画ファイルはアプリに含まれません。外出先から使う場合も、サーバーへ接続できるネットワークが必要です。現在の実装基準は KonomiTV の master `0775594`（client のバージョン表記 0.14.1）です。

## AltStore Classic でインストールする

1. [AltStore Classic の Mac 用手順](https://faq.altstore.io/altstore-classic/how-to-install-altstore-macos)または [Windows 用手順](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows)に従い、端末へ AltStore を導入します。必要に応じて iOS の開発者モードを有効にします。
2. このリポジトリの [Actions](https://github.com/CentralLiner/Konomios/actions/workflows/build-ipa.yml) を開き、成功した最新の **Build iOS IPA** を選択します。
3. Artifacts から `KonomiTV-AltStore-unsigned-数字` をダウンロードして ZIP を展開します。中の `KonomiTV.ipa` を iPhone の「ファイル」へ保存します。
4. AltStore の **My Apps → ＋** から `KonomiTV.ipa` を選びます。AltStore が自分のアカウント用に署名してインストールします。
5. アプリを開き、KonomiTV の HTTPS URL を登録します。例：`https://192-168-1-10.local.konomi.tv:7000/`。Safari / PWA とは保存領域が別なので、KonomiTV アカウントにはアプリ内でログインします。

更新時も同じ手順で新しい IPA を選び、既存の Konomios を上書きしてください。同じ Bundle ID と Apple アカウントで更新すると、接続先・履歴・ログイン情報を引き継げます。

IPA は AltStore が再署名する前提の署名なし実機ビルドです。Apple ID、パスワード、開発証明書を GitHub Actions に登録する必要はありません。AltStore PAL は任意の IPA のサイドロード用途とは異なります。[Classic と PAL の違い](https://faq.altstore.io/altstore-pal-v.-altstore-classic)

無料 Apple アカウントでは通常 7 日以内の更新が必要で、アクティブなアプリは AltStore 自身を含めて 3 つまでです。更新方法や現行の制限は [AltStore My Apps](https://faq.altstore.io/altstore-classic/your-altstore) を確認してください。

## 視聴する

- 番組表、ライブ視聴、録画再生、KonomiTV の設定は既存 Web UI を使います。
- 視聴画面の従来のフルスクリーンボタンは「横画面に固定」へ置き換えています。KonomiTV の通常の横画面レイアウトで、コメント・字幕・操作ボタンを表示します。もう一度押すと固定を解除して元の向きに戻ります。視聴画面から離れた場合も解除します。
- 常設のネイティブヘッダーはありません。接続先の設定と再読み込みは KonomiTV の「マイページ」「設定」、ログイン画面、プレイヤーの歯車メニューから開きます。
- 上端と左右はネイティブのセーフエリア内に収め、下端はホームバー領域まで描画します。視聴画面の Web UI が確保する下端の余白も削除します。WebKit の Fullscreen API は無効化しているため、システムの全画面通知と閉じるボタンは表示しません。
- ホームへ戻る前にプレイヤーの PiP ボタンを押すと、小窓で視聴を継続できます。PiP 中は再読み込みと接続先変更を抑止し、同じ WebView を保持します。

接続先の設定画面には、接続に成功したサーバーを履歴として保存します。履歴をタップすると再接続でき、ピン留めしたサーバーを上に表示します。ピン留め解除・削除もできます。履歴の削除はログイン情報や現在の接続を消しません。削除したサーバーへ再び接続に成功すると履歴に再登録されます。旧版からは保存済みの接続先を一度だけ移行します。

接続失敗や HTTP エラーでは、エラー表示から接続先の設定と再読み込みを行えます。誤った URL が通常の HTML を返した場合にも、KonomiTV の UI が見つからなければ約 5 秒後にページ末尾へ同じ操作を追加します。

ホーム移動時の自動 PiP は実機で安定しなかったため取り除きました。アプリ独自の HLS 組み替え・ローカル配信・AVPlayer への切り替えも行いません。既存の KonomiTV プレイヤーを保持し、再生・一時停止・ミュートの状態を上書きしません。

PiP は動画と音声を表示します。Web の別 Canvas / DOM に描画されるコメントや ARIB 字幕は PiP には合成しません。通常の H.264 画質を最初の確認に使ってください。Original MPEG-2、HEVC、オフライン保存など別の再生経路は実機で追加確認が必要です。

## 実装

- `allowsInlineMediaPlayback`、`allowsPictureInPictureMediaPlayback` を有効化。`isElementFullscreenEnabled` は無効化
- WebView 作成前に `.playback` 音声カテゴリを設定し、音声の有効化・割り込みは WebKit に委ねる。再生開始後に競合するネイティブ音声セッションを有効化しない。Background Modes の `audio`
- 全画面ボタン・F キー・動画のダブルクリックを横画面固定の要求へ置き換え、`UIWindowScene.requestGeometryUpdate` と対応する向きのマスクで回転する。解除は同じボタンまたは Escape キー。WebView は同じ親ビューで上端・左右のセーフエリアを守り、下端は画面端までサイズを更新し、動画を再読み込みしない
- 手動 PiP は Web のクリック処理から同期的に要求。WebKit presentation mode と標準 PiP に対応
- 設定・マイページ・ログイン・プレイヤー設定パネルに接続先設定と再読み込みを追加。接続履歴の保存・ピン留め・削除に対応
- video 要素の交換を検出し、画質変更前に古い PiP を終了
- 録画の session_id を既存の通信から観測し、PiP 中だけ 4 秒間隔のネイティブ Keep-Alive で補助
- HTTPS の接続先検証、永続設定、メインフレームと同一オリジンに限定したネイティブ連携

補助 Keep-Alive は `/api/streams/video/.../keep-alive` のみへ送信します。トークンや Cookie を複製しません。現在の KonomiTV ではこの API に認証はありません。リバースプロキシで API に追加認証をかけている構成には、この補助機能が利用できない場合があります。動画の受信・変換・バッファ供給は引き続き WebKit と既存プレイヤーが担当し、ネイティブ Keep-Alive だけでバックグラウンド再生全体を保証するものではありません。

既存 KonomiTV のバンドルは書き換えず、小さなアプリ固有の連携スクリプトを追加しています。KonomiTV の設定メニュー、DPlayer の PiP ボタン、video 要素、録画 API に依存する箇所は、KonomiTV 更新時に再確認してください。

サーバー URL の配下パスも保存できますが、KonomiTV の既存クライアントは API を同じオリジンの `/api` へ要求します。リバースプロキシを使う場合は、Web UI のパスだけでなく `/api` も同じオリジンで提供してください。

## ビルド

`push` と Pull Request で GitHub Actions が実行されます。Actions の **Run workflow** でも再実行できます。macOS ランナーで次を実施します。

1. プロジェクト構造と JavaScript 連携テストを確認
2. 使用可能な iOS 18.3 以降の iPhone シミュレーターで Swift の URL / セッション / 履歴 / WebView 配置のテストを実行
3. iPhoneOS 向けの arm64 アプリをビルドし、`Payload/KonomiTV.app` を含む IPA と SHA-256 を生成

Mac と Xcode がある場合は、次のコマンドでもビルドできます。

```bash
bash scripts/build-ipa.sh
```

出力は `dist/KonomiTV.ipa` と `dist/KonomiTV.ipa.sha256` です。任意の Bundle ID を使う場合は `BUNDLE_IDENTIFIER=自分の識別子` を指定します。Xcode から直接実機に入れる場合は `KonomiTV.xcodeproj` を開き、Signing & Capabilities で自分の Team と Bundle Identifier を設定してください。

## 実機での確認

自動テストは横画面ボタン・固定解除・視聴画面からの離脱、手動 PiP、ホーム移動時に自動要求や再生状態の上書きをしないこと、設定操作の連携、URL の安全性、セッション、履歴の永続化、WebView の配置を確認します。実際の KonomiTV 配信を使う横画面表示と PiP は実機で確認してください。

- ライブと録画の横画面固定・解除、およびシステムの全画面通知と閉じるボタンが表示されないこと
- 横画面固定の解除後に元の向きへ戻ること、歯車の接続先設定を開けること
- PiP ボタンで開始した後に Home へ戻り、映像と音声が継続すること
- PiP 開始後、別アプリで各 10 分以上の映像・音声再生
- 録画を PiP で 30 秒以上一時停止した後の再開
- PiP から視聴画面への復帰、画質・番組の変更
- Wi-Fi / モバイル回線の切り替えと音声割り込み後の復帰
- 接続成功の履歴保存、アプリ再起動後の保持、ピン留め順序、削除と再接続

アプリの構成と採用条件は [設計方針](docs/ios-wrapper-plan.md) にまとめています。

## ライセンス

このアプリのコードは [MIT License](LICENSE) です。KonomiTV は別プロジェクトです。
