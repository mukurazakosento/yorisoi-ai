import Foundation
import ScreenCaptureKit
import Vision
import CoreMedia
import CoreVideo

@available(iOS 27.0, *)
final class ScreenCaptureCoordinator: NSObject,
                                      SCStreamOutput,
                                      SCStreamDelegate,
                                      SCContentSharingPickerObserver {

    // MARK: - Callbacks

    var onOCR: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var onCaptureStarted: (() -> Void)?

    // MARK: - Screen Capture

    private var stream: SCStream?

    private let picker = SCContentSharingPicker.shared

    private let captureQueue = DispatchQueue(
        label: "yorisoi.capture.queue",
        qos: .userInitiated
    )

    private let visionQueue = DispatchQueue(
        label: "yorisoi.vision.queue",
        qos: .userInitiated
    )

    // PickerのObserverを登録済みか
    private var pickerObserverAdded = false

    // OCRの最後の実行時刻
    private var lastOCRTime: Date = .distantPast

    // OCR間隔
    private let ocrInterval: TimeInterval = 0.8

    // MARK: - Init

    override init() {
        super.init()

        print("✅ ScreenCaptureCoordinator 初期化")
    }

    deinit {

        if pickerObserverAdded {
            picker.remove(self)
        }

        print("🛑 ScreenCaptureCoordinator 解放")
    }

    // MARK: - Start

    func startFullDisplayCapture() {

        DispatchQueue.main.async { [weak self] in

            guard let self else {
                return
            }

            // 二重起動防止
            if self.stream != nil {

                self.onStatus?(
                    "⚠️ 画面キャプチャはすでに動いています"
                )

                return
            }

            self.onStatus?(
                "📱 画面共有を準備しています"
            )

            // ------------------------------------------------
            // 1. Picker設定
            // ------------------------------------------------

            var configuration =
                SCContentSharingPickerConfiguration()

            // マイクは使わない
            configuration.showsMicrophoneControl = false

            // ------------------------------------------------
            // 2. Picker設定を登録
            // ------------------------------------------------

            self.picker.defaultConfiguration =
                configuration

            // ------------------------------------------------
            // 3. Observer登録
            // ------------------------------------------------

            if !self.pickerObserverAdded {

                self.picker.add(self)
                self.pickerObserverAdded = true

                print(
                    "✅ ScreenCapturePicker Observer 登録"
                )
            }

            // ------------------------------------------------
            // 4. 全画面Pickerを表示
            // ------------------------------------------------

            print(
                "📱 全画面共有Pickerを表示します"
            )

            self.onStatus?(
                "📱 画面共有の選択画面を開いています"
            )

            self.picker.present(
                using: .display
            )
        }
    }

    // MARK: - Stop

    func stop() {

        guard let currentStream = stream else {

            onStatus?(
                "待機中"
            )

            return
        }

        stream = nil

        Task {

            do {

                try await currentStream.stopCapture()

                await MainActor.run {

                    self.onStatus?(
                        "停止しました"
                    )
                }

                print(
                    "🛑 画面キャプチャ停止"
                )

            } catch {

                await MainActor.run {

                    self.onStatus?(
                        "⚠️ 停止エラー: \(error.localizedDescription)"
                    )
                }

                print(
                    "❌ stopCaptureエラー: \(error.localizedDescription)"
                )
            }
        }
    }

    // MARK: - Picker Observer
    //
    // ユーザーが「画面全体」を選択したあとに呼ばれる
    //

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {

        print(
            "✅ ScreenCaptureKit: 共有対象を取得しました"
        )

        DispatchQueue.main.async { [weak self] in

            self?.onStatus?(
                "✅ 画面共有対象を取得しました"
            )
        }

        // 古いStreamがあれば停止
        if let oldStream = self.stream {

            Task {

                do {

                    try await oldStream.stopCapture()

                } catch {

                    print(
                        "⚠️ 古いStream停止エラー: \(error.localizedDescription)"
                    )
                }
            }

            self.stream = nil
        }

        // 新しいStreamを開始
        startStream(
            with: filter
        )
    }

    // MARK: - Picker Cancel

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {

        print(
            "ℹ️ 画面共有がキャンセルされました"
        )

        DispatchQueue.main.async { [weak self] in

            self?.onStatus?(
                "画面共有がキャンセルされました"
            )
        }
    }

    // MARK: - Picker Error

    func contentSharingPickerStartDidFailWithError(
        _ error: any Error
    ) {

        print(
            "❌ Picker開始エラー: \(error.localizedDescription)"
        )

        DispatchQueue.main.async { [weak self] in

            self?.onStatus?(
                "❌ 画面共有開始エラー: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Create Stream

    private func startStream(
        with filter: SCContentFilter
    ) {

        print(
            "▶️ SCStreamを作成します"
        )

        var configuration =
            SCStreamConfiguration()

        // iOSではmacOS専用の
        // pixelFormat / queueDepth / minimumFrameInterval
        // を設定しない

        let newStream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: self
        )

        do {

            // 画面フレームを受信
            try newStream.addStreamOutput(
                self,
                type: .screen,
                sampleHandlerQueue: captureQueue
            )

            self.stream = newStream

            print(
                "✅ SCStream作成成功"
            )

            DispatchQueue.main.async { [weak self] in

                self?.onStatus?(
                    "画面キャプチャを開始しています"
                )
            }

            Task {

                do {

                    try await newStream.startCapture()

                    print(
                        "✅ SCStream開始成功"
                    )

                    await MainActor.run {

                        self.onStatus?(
                            "✅ 画面キャプチャ中"
                        )

                        self.onCaptureStarted?()
                    }

                } catch {

                    print(
                        "❌ startCaptureエラー: \(error.localizedDescription)"
                    )

                    self.stream = nil

                    await MainActor.run {

                        self.onStatus?(
                            "❌ キャプチャ開始失敗: \(error.localizedDescription)"
                        )
                    }
                }
            }

        } catch {

            print(
                "❌ addStreamOutputエラー: \(error.localizedDescription)"
            )

            self.stream = nil

            DispatchQueue.main.async { [weak self] in

                self?.onStatus?(
                    "❌ 画面出力設定エラー: \(error.localizedDescription)"
                )
            }
        }
    }

    // MARK: - SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {

        // 画面だけ処理
        guard type == .screen else {
            return
        }

        // バッファ確認
        guard sampleBuffer.isValid else {
            return
        }

        // 画像取得
        guard let pixelBuffer =
                CMSampleBufferGetImageBuffer(
                    sampleBuffer
                )
        else {

            DispatchQueue.main.async { [weak self] in

                self?.onStatus?(
                    "⚠️ 画面画像を取得できません"
                )
            }

            return
        }

        let now = Date()

        // OCR間隔
        guard now.timeIntervalSince(lastOCRTime)
                >= ocrInterval
        else {
            return
        }

        lastOCRTime = now

        // OCR実行
        visionQueue.async { [weak self] in

            guard let self else {
                return
            }

            self.performOCR(
                pixelBuffer: pixelBuffer
            )
        }
    }

    // MARK: - OCR

    private func performOCR(
        pixelBuffer: CVPixelBuffer
    ) {

        DispatchQueue.main.async { [weak self] in

            self?.onStatus?(
                "✅ 画面フレーム取得 → OCR解析中"
            )
        }

        let request = VNRecognizeTextRequest {

            [weak self] request, error in

            guard let self else {
                return
            }

            // エラー
            if let error {

                print(
                    "❌ Vision OCRエラー: \(error.localizedDescription)"
                )

                DispatchQueue.main.async {

                    self.onStatus?(
                        "⚠️ OCRエラー: \(error.localizedDescription)"
                    )
                }

                return
            }

            // 結果
            guard let observations =
                    request.results
                    as? [VNRecognizedTextObservation]
            else {

                DispatchQueue.main.async {

                    self.onStatus?(
                        "⚠️ OCR結果を取得できません"
                    )
                }

                return
            }

            var recognizedTexts: [String] = []

            for observation in observations {

                guard let candidate =
                        observation.topCandidates(1).first
                else {
                    continue
                }

                let value =
                    candidate.string.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )

                guard !value.isEmpty else {
                    continue
                }

                recognizedTexts.append(
                    value
                )
            }

            let text =
                recognizedTexts.joined(
                    separator: "\n"
                )

            DispatchQueue.main.async {

                if text.isEmpty {

                    print(
                        "⚠️ OCR結果: 文字なし"
                    )

                    self.onStatus?(
                        "⚠️ 画面は取得できていますが、OCRで文字を認識できません"
                    )

                } else {

                    print(
                        "✅ OCR成功: \(recognizedTexts.count)項目"
                    )

                    print(
                        "🔎 OCR結果:"
                    )

                    print(text)

                    self.onStatus?(
                        "✅ OCR成功（\(recognizedTexts.count)項目）"
                    )

                    self.onOCR?(
                        text
                    )
                }
            }
        }

        // 高精度OCR
        request.recognitionLevel = .accurate

        // 日本語・英語
        request.recognitionLanguages = [
            "ja-JP",
            "en-US"
        ]

        // 言語補正
        request.usesLanguageCorrection = true

        // よく使う単語
        request.customWords = [
            "LINE",
            "Safari",
            "Google",
            "写真",
            "画像",
            "送信",
            "トーク",
            "電話",
            "設定",
            "連絡先",
            "検索",
            "検索結果",
            "メッセージ",
            "孫"
        ]

        // 小さすぎる文字を除外
        request.minimumTextHeight =
            0.012

        // Visionへ渡す
        let handler =
            VNImageRequestHandler(
                cvPixelBuffer: pixelBuffer,
                orientation: .up,
                options: [:]
            )

        do {

            try handler.perform([
                request
            ])

        } catch {

            print(
                "❌ OCR実行エラー: \(error.localizedDescription)"
            )

            DispatchQueue.main.async { [weak self] in

                self?.onStatus?(
                    "⚠️ OCR実行エラー: \(error.localizedDescription)"
                )
            }
        }
    }

    // MARK: - Stream Delegate

    func streamDidBecomeActive(
        _ stream: SCStream
    ) {

        print(
            "🟢 SCStream Active"
        )

        DispatchQueue.main.async { [weak self] in

            self?.onStatus?(
                "🟢 画面キャプチャが有効です"
            )
        }
    }

    func streamDidBecomeInactive(
        _ stream: SCStream
    ) {

        print(
            "🟡 SCStream Inactive"
        )

        DispatchQueue.main.async { [weak self] in

            self?.onStatus?(
                "🟡 画面キャプチャが一時停止しました"
            )
        }
    }

    func stream(
        _ stream: SCStream,
        didStopWithError error: Error
    ) {

        print(
            "🔴 SCStream停止: \(error.localizedDescription)"
        )

        self.stream = nil

        DispatchQueue.main.async { [weak self] in

            self?.onStatus?(
                "🔴 画面キャプチャ停止: \(error.localizedDescription)"
            )
        }
    }
}
