import Foundation
import ScreenCaptureKit
import Vision
import CoreMedia
import CoreVideo

final class ScreenCaptureCoordinator: NSObject,
                                      SCContentSharingPickerObserver,
                                      SCStreamOutput,
                                      SCStreamDelegate {

    // MARK: - Callbacks

    /// OCRで読み取った画面上の文字を返す
    var onOCR: ((String) -> Void)?

    /// 状態表示用
    var onStatus: ((String) -> Void)?

    // MARK: - Screen Capture

    private let picker = SCContentSharingPicker.shared
    private var stream: SCStream?

    private let screenFrameQueue = DispatchQueue(
        label: "jp.yorisoi.screencapture.screen-frame"
    )

    // MARK: - OCR

    private var lastOCRTime: CFTimeInterval = 0
    private let ocrInterval: CFTimeInterval = 0.8

    // MARK: - State

    private var isPaused = false

    override init() {
        super.init()

        picker.add(self)
        picker.isActive = true

        onStatus?("画面キャプチャ準備完了")
    }

    deinit {
        picker.isActive = false
    }

    // MARK: - Start

    /// iPhone全体の画面共有を開始
    func startFullDisplayCapture() async throws {

        await MainActor.run {
            self.onStatus?("画面共有の確認を表示しています")

            // システム標準の画面共有ピッカーを表示
            self.picker.present(using: .display)
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

        let currentStream = stream
        stream = nil

        guard let currentStream else {
            onStatus?("画面キャプチャ：停止")
            return
        }

        Task {
            do {
                try await currentStream.stopCapture()
            } catch {
                print("画面キャプチャ停止エラー: \(error)")
            }

            await MainActor.run {
                self.onStatus?("画面キャプチャ：停止")
            }
        }
    }

    // MARK: - SCContentSharingPickerObserver

    /// ユーザーが画面共有対象を選択したとき
    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {

        // 既存ストリームがある場合はフィルターだけ更新
        if let existingStream = stream {
            do {
                existingStream.updateContentFilter(filter) { error in

                    if let error {
                        print("フィルター更新エラー: \(error)")
                    } else {
                        print("フィルター更新成功")
                    }
                }
            }

            return
        }

        // 新しいストリームを作成
        let configuration = SCStreamConfiguration()

        // 画面だけ取得
        configuration.capturesAudio = false

        // 過剰に大量のフレームを溜めない
        configuration.queueDepth = 3

        // OCR用なので60fpsは不要
        configuration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: 10
        )

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

            stream = newStream

            onStatus?("画面キャプチャ開始")

            Task {
                do {
                    try await newStream.startCapture()

                    await MainActor.run {
                        self.onStatus?("画面を確認中")
                    }

                } catch {

                    await MainActor.run {
                        self.onStatus?(
                            "画面キャプチャ開始エラー: \(error.localizedDescription)"
                        )
                    }

                    print(
                        "SCStream startCapture error: \(error)"
                    )
                }
            }

        } catch {

            onStatus?(
                "画面出力設定エラー: \(error.localizedDescription)"
            )

            print(
                "addStreamOutput error: \(error)"
            )
        }
    }

    /// ユーザーが画面共有をキャンセルしたとき
    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {

        onStatus?("画面共有がキャンセルされました")

        if let stream {
            stream.stopCapture { error in
                if let error {
                    print(
                        "キャンセル時の停止エラー: \(error)"
                    )
                }
            }
        }
    }

    /// 画面共有ピッカー開始に失敗したとき
    func contentSharingPickerStartDidFailWithError(
        _ error: any Error
    ) {

        onStatus?(
            "画面共有を開始できませんでした: \(error.localizedDescription)"
        )

        print(
            "Content Sharing Picker error: \(error)"
        )
    }

    // MARK: - SCStreamOutput

    /// 画面フレームを受け取る
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {

        guard type == .screen else {
            return
        }

        guard !isPaused else {
            return
        }

        guard let pixelBuffer = sampleBuffer.imageBuffer else {
            return
        }

        // OCRしすぎないように間引く
        let now = CACurrentMediaTime()

        guard now - lastOCRTime >= ocrInterval else {
            return
        }

        lastOCRTime = now

        performOCR(on: pixelBuffer)
    }

    // MARK: - OCR

    private func performOCR(on pixelBuffer: CVPixelBuffer) {

        let request = VNRecognizeTextRequest { [weak self] request, error in

            guard let self else {
                return
            }

            if let error {
                print(
                    "OCRエラー: \(error.localizedDescription)"
                )
                return
            }

            guard let observations =
                    request.results as? [VNRecognizedTextObservation]
            else {
                return
            }

            let texts = observations.compactMap { observation in

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

            self.onOCR?(fullText)
        }

        request.recognitionLevel = .fast
        request.usesLanguageCorrection = true

        // 日本語 + 英語
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
                "Vision OCR実行エラー: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - SCStreamDelegate

    func stream(
        _ stream: SCStream,
        didStopWithError error: any Error
    ) {

        print(
            "SCStream stopped: \(error.localizedDescription)"
        )

        Task {
            await MainActor.run {
                self.onStatus?(
                    "画面キャプチャが停止しました"
                )
            }
        }

        if self.stream === stream {
            self.stream = nil
        }
    }
}
