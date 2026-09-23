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

    // MARK: - Screen Capture

    private let picker = SCContentSharingPicker.shared
    private var stream: SCStream?

    private let screenFrameQueue = DispatchQueue(
        label: "jp.yorisoi.screencapture.screen-frame"
    )

    // MARK: - OCR

    private var lastOCRTime: CFTimeInterval = 0

    // 約1秒に1回OCRする
    private let ocrInterval: CFTimeInterval = 0.8

    // MARK: - State

    private var isPaused = false

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
            onStatus?("画面キャプチャ：停止")
            return
        }

        stream = nil

        Task {
            do {
                try await currentStream.stopCapture()
            } catch {
                print(
                    "画面キャプチャ停止エラー: \(error.localizedDescription)"
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

        // iOSでは既存SCStreamの
        // updateContentFilter が利用できないため、
        // 最初の選択時だけ新規ストリームを作る。
        if stream != nil {
            onStatus?("画面共有設定を更新しました")
            return
        }

        // 念のため既存ストリームがあれば停止
        if let oldStream = self.stream {
            self.stream = nil

            Task {
                try? await oldStream.stopCapture()
            }
        }

        let configuration = SCStreamConfiguration()

        // 音声は不要
        configuration.capturesAudio = false

        // iOSではqueueDepth / minimumFrameIntervalを
        // 明示設定しない。
        // OCR側で処理頻度を制御する。

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

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {

        onStatus?("画面共有がキャンセルされました")
    }

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

        // OCRを毎フレーム実行しない
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

        if self.stream === stream {
            self.stream = nil
        }

        Task {
            await MainActor.run {
                self.onStatus?(
                    "画面キャプチャが停止しました"
                )
            }
        }
    }
}
