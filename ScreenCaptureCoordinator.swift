import Foundation
import ScreenCaptureKit
import Vision
import CoreMedia
import CoreVideo
import QuartzCore

@available(iOS 27.0, *)
final class ScreenCaptureCoordinator: NSObject,
                                      SCContentSharingPickerObserver,
                                      SCStreamOutput,
                                      SCStreamDelegate {

    // MARK: - Callbacks

    var onOCR: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var onCaptureStarted: (() -> Void)?

    // MARK: - Screen Capture

    private let picker = SCContentSharingPicker.shared
    private var stream: SCStream?

    private let screenFrameQueue = DispatchQueue(
        label: "jp.yorisoi.screencapture.screen-frame"
    )

    // MARK: - OCR

    private var lastOCRTime: CFTimeInterval = 0

    // 約0.8秒に1回OCR
    private let ocrInterval: CFTimeInterval = 0.8

    // MARK: - State

    private var isPaused = false
    private var isCapturing = false

    // MARK: - Init

    override init() {
        super.init()

        picker.add(self)
        picker.isActive = true

        onStatus?("画面キャプチャ準備完了")
    }

    deinit {
        picker.remove(self)
        picker.isActive = false
    }

    // MARK: - Start

    func startFullDisplayCapture() async throws {

        await MainActor.run {
            self.onStatus?("画面共有の確認を表示しています")

            // iOS 27のシステム画面共有ピッカー
            self.picker.present()
        }
    }

    // MARK: - Pause / Resume

    func pauseAnalysis() {
        isPaused = true
        onStatus?("画面解析：一時停止")
    }

    func resumeAnalysis() {
        isPaused = false
        onStatus?("画面解析：再開")
    }

    // MARK: - Stop

    func stop() {

        guard let currentStream = stream else {
            isCapturing = false
            onStatus?("画面キャプチャ：停止")
            return
        }

        stream = nil
        isCapturing = false

        Task {
            do {
                try await currentStream.stopCapture()

                print("✅ SCStream stopCapture 完了")

            } catch {
                print(
                    "❌ 画面キャプチャ停止エラー: \(error.localizedDescription)"
                )
            }

            await MainActor.run {
                self.onStatus?("画面キャプチャ：停止")
            }
        }
    }

    // MARK: - SCContentSharingPickerObserver

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {

        print("📡 ContentSharingPicker didUpdateWith")

        // iOSでは既存SCStreamの
        // updateContentFilter が利用できないため、
        // 新しい選択が来た場合は既存ストリームを止めて
        // 新しいストリームを作る。

        if let existingStream = self.stream {
            print("⚠️ 既存SCStreamを停止して作り直します")

            self.stream = nil
            self.isCapturing = false

            Task {
                do {
                    try await existingStream.stopCapture()
                    print("✅ 既存SCStream停止完了")
                } catch {
                    print(
                        "⚠️ 既存SCStream停止エラー: \(error.localizedDescription)"
                    )
                }
            }
        }

        // iOS用ストリーム設定
        let configuration = SCStreamConfiguration()

        // 音声は不要
        configuration.capturesAudio = false

        // iOSでは
        // queueDepth
        // minimumFrameInterval
        // captureMicrophone
        // などを明示設定しない。

        let newStream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: self
        )

        do {

            try newStream.addStreamOutput(
                self,
                type: .screen,
                sampleHandlerQueue: screenFrameQueue
            )

            self.stream = newStream

            onStatus?("画面キャプチャ開始")

            print("✅ SCStream作成完了")

            Task {

                do {

                    try await newStream.startCapture()

                    self.isCapturing = true

                    print("✅ SCStream startCapture 成功")

                    await MainActor.run {
                        self.onStatus?("画面を確認中")
                        self.onCaptureStarted?()
                    }

                } catch {

                    self.isCapturing = false

                    print(
                        "❌ SCStream startCapture エラー: \(error.localizedDescription)"
                    )

                    await MainActor.run {
                        self.onStatus?(
                            "画面キャプチャ開始エラー: \(error.localizedDescription)"
                        )
                    }
                }
            }

        } catch {

            self.isCapturing = false

            onStatus?(
                "画面出力設定エラー: \(error.localizedDescription)"
            )

            print(
                "❌ addStreamOutput エラー: \(error)"
            )
        }
    }

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {

        print("⚠️ 画面共有がキャンセルされました")

        onStatus?("画面共有がキャンセルされました")
    }

    func contentSharingPickerStartDidFailWithError(
        _ error: any Error
    ) {

        print(
            "❌ Content Sharing Picker エラー: \(error.localizedDescription)"
        )

        onStatus?(
            "画面共有を開始できませんでした: \(error.localizedDescription)"
        )
    }

    // MARK: - SCStreamDelegate
    // ストリームが有効になった

    func streamDidBecomeActive(
        _ stream: SCStream
    ) {

        isCapturing = true

        print("✅ SCStream active")

        Task {
            await MainActor.run {
                self.onStatus?("画面キャプチャ：稼働中")
            }
        }
    }

    // ストリームが一時的に無効になった

    func streamDidBecomeInactive(
        _ stream: SCStream
    ) {

        print("⚠️ SCStream inactive")

        Task {
            await MainActor.run {
                self.onStatus?("画面キャプチャ：一時停止")
            }
        }
    }

    // MARK: - SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {

        // 画面映像以外は無視
        guard type == .screen else {
            return
        }

        // プライバシーモードなどで停止中
        guard !isPaused else {
            return
        }

        // 画像バッファ取得
        guard let pixelBuffer = sampleBuffer.imageBuffer else {
            return
        }

        // OCRを毎フレーム実行しない
        let now = CACurrentMediaTime()

        guard now - lastOCRTime >= ocrInterval else {
            return
        }

        lastOCRTime = now

        performOCR(on: pixelBuffer)
    }

    // MARK: - OCR

    private func performOCR(
        on pixelBuffer: CVPixelBuffer
    ) {

        let request = VNRecognizeTextRequest {
            [weak self] request, error in

            guard let self else {
                return
            }

            if let error {
                print(
                    "❌ OCRエラー: \(error.localizedDescription)"
                )
                return
            }

            guard let observations =
                    request.results as? [VNRecognizedTextObservation]
            else {
                return
            }

            let texts = observations.compactMap {
                observation -> String? in

                observation
                    .topCandidates(1)
                    .first?
                    .string
            }

            let fullText = texts
                .joined(separator: "\n")
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )

            guard !fullText.isEmpty else {
                return
            }

            print("🔎 OCR:")
            print(fullText)

            self.onOCR?(fullText)
        }

        // 高速OCR
        request.recognitionLevel = .fast

        // 日本語補正
        request.usesLanguageCorrection = true

        request.recognitionLanguages = [
            "ja-JP",
            "en-US"
        ]

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .up,
            options: [:]
        )

        do {

            try handler.perform([request])

        } catch {

            print(
                "❌ Vision OCR実行エラー: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - SCStreamDelegate
    // ストリームがエラーで停止した

    func stream(
        _ stream: SCStream,
        didStopWithError error: any Error
    ) {

        isCapturing = false

        print("❌ SCStream stopped")
        print(
            "❌ エラー: \(error.localizedDescription)"
        )

        if self.stream === stream {
            self.stream = nil
        }

        Task {

            await MainActor.run {

                self.onStatus?(
                    "画面キャプチャ停止: \(error.localizedDescription)"
                )
            }
        }
    }
}
