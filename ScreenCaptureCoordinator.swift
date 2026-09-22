import Foundation
import ScreenCaptureKit
import Vision
import CoreMedia

@preconcurrency
final class ScreenCaptureCoordinator: NSObject,
                                      SCContentSharingPickerObserver,
                                      SCStreamOutput,
                                      SCStreamDelegate {

    private let picker = SCContentSharingPicker.shared

    private var stream: SCStream?
    private let queue = DispatchQueue(
        label: "jp.yorisoi.capture",
        qos: .userInitiated
    )

    private var privacyPaused = false
    private var lastAnalysis = Date.distantPast
    private let analysisInterval: TimeInterval = 1.2

    var onOCR: ((String) -> Void)?
    var onStatus: ((String) -> Void)?

    override init() {
        super.init()
        picker.add(self)
        picker.isActive = true
    }

    deinit {
        picker.remove(self)
        picker.isActive = false
    }

    func startFullDisplayCapture() async throws {
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = .singleDisplay
        configuration.allowsChangingSelectedContent = false

        picker.defaultConfiguration = configuration

        onStatus?("画面共有の許可を待っています。")
        picker.present(using: .display)
    }

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        Task {
            do {
                try await startStream(with: filter)
            } catch {
                onStatus?("画面取得エラー：\(error.localizedDescription)")
            }
        }
    }

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        onStatus?("画面共有がキャンセルされました。")
    }

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        onStatus?("画面共有を開始できませんでした。")
    }

    private func startStream(with filter: SCContentFilter) async throws {
        if let existing = stream {
            try? await existing.stopCapture()
        }

        let config = SCStreamConfiguration()

        config.capturesAudio = false
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(
            value: 1,
            timescale: 2
        )
        config.queueDepth = 2

        let newStream = SCStream(
            filter: filter,
            configuration: config,
            delegate: self
        )

        try newStream.addStreamOutput(
            self,
            type: .screen,
            sampleHandlerQueue: queue
        )

        stream = newStream

        try await newStream.startCapture()

        onStatus?("画面取得：実行中")
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }
        guard !privacyPaused else { return }

        let now = Date()

        guard now.timeIntervalSince(lastAnalysis) >= analysisInterval else {
            return
        }

        lastAnalysis = now

        guard let pixelBuffer =
                CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        recognizeText(from: pixelBuffer)
    }

    private func recognizeText(from pixelBuffer: CVPixelBuffer) {
        let request = VNRecognizeTextRequest { [weak self] request, _ in
            guard let self else { return }

            let observations =
                (request.results as? [VNRecognizedTextObservation]) ?? []

            let text = observations
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty else { return }

            self.onOCR?(text)
        }

        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false

        if #available(iOS 18.0, *) {
            request.recognitionLanguages = ["ja-JP", "en-US"]
        }

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .up,
            options: [:]
        )

        do {
            try handler.perform([request])
        } catch {
            // 試作なので個々のOCR失敗では停止しない。
        }
    }

    func pauseAnalysis() {
        privacyPaused = true
    }

    func resumeAnalysis() {
        privacyPaused = false
    }

    func stop() {
        Task {
            if let stream {
                try? await stream.stopCapture()
            }

            self.stream = nil
            self.onStatus?("画面取得：停止中")
        }
    }

    func stream(
        _ stream: SCStream,
        didStopWithError error: any Error
    ) {
        onStatus?("画面取得が停止しました。")
    }
}
