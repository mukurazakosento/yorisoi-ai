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

    // OCRは約1.2秒に1回だけ実行
    // 画面そのものは継続的に取得する
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


    // =========================================================
    // 画面共有開始
    // =========================================================

    func startFullDisplayCapture() async throws {

        // iOSではMac向けの
        // allowedPickerModes / allowsChangingSelectedContent
        // をここでは設定しない。
        var configuration =
            SCContentSharingPickerConfiguration()

        // iOSで使える基本設定だけを使用
        configuration.showsMicrophoneControl = false

        picker.defaultConfiguration =
            configuration

        onStatus?(
            "画面共有の許可を待っています。"
        )

        // AppleのiOS向けサンプルと同じく
        // full-display picker は present() を使う。
        picker.present()
    }


    // =========================================================
    // Pickerから画面選択結果を受け取る
    // =========================================================

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {

        Task {

            do {

                try await startStream(
                    with: filter
                )

            } catch {

                onStatus?(
                    "画面取得エラー：\(error.localizedDescription)"
                )
            }
        }
    }


    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {

        onStatus?(
            "画面共有がキャンセルされました。"
        )
    }


    func contentSharingPickerStartDidFailWithError(
        _ error: any Error
    ) {

        onStatus?(
            "画面共有を開始できませんでした：\(error.localizedDescription)"
        )
    }


    // =========================================================
    // SCStream開始
    // =========================================================

    private func startStream(
        with filter: SCContentFilter
    ) async throws {

        // すでにストリームがあれば停止
        if let existing = stream {

            try? await existing.stopCapture()

            stream = nil
        }


        // iOSではMac専用の
        // showsCursor / minimumFrameInterval / queueDepth
        // を設定しない。
        //
        // iOSのデフォルト設定を利用する。
        let config =
            SCStreamConfiguration()

        config.capturesAudio = false


        let newStream =
            SCStream(
                filter: filter,
                configuration: config,
                delegate: self
            )


        try newStream.addStreamOutput(
            self,
            type: .screen,
            sampleHandlerQueue: queue
        )


        stream =
            newStream


        try await newStream.startCapture()


        onStatus?(
            "画面取得：実行中"
        )
    }


    // =========================================================
    // 画面フレームを受け取る
    // =========================================================

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {

        guard type == .screen else {
            return
        }

        // プライバシーモード中は解析しない
        guard !privacyPaused else {
            return
        }


        let now =
            Date()


        // OCRを毎フレーム行わない
        guard
            now.timeIntervalSince(lastAnalysis)
                >= analysisInterval
        else {
            return
        }


        lastAnalysis =
            now


        guard
            let pixelBuffer =
                CMSampleBufferGetImageBuffer(
                    sampleBuffer
                )
        else {
            return
        }


        recognizeText(
            from: pixelBuffer
        )
    }


    // =========================================================
    // OCR
    // =========================================================

    private func recognizeText(
        from pixelBuffer: CVPixelBuffer
    ) {

        let request =
            VNRecognizeTextRequest {

                [weak self]
                request,
                error in


                guard
                    error == nil,
                    let observations =
                        request.results
                        as? [VNRecognizedTextObservation]
                else {
                    return
                }


                let text =
                    observations
                        .compactMap {
                            $0
                                .topCandidates(1)
                                .first?
                                .string
                        }
                        .joined(separator: " ")
                        .trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )


                guard !text.isEmpty else {
                    return
                }


                self?.onOCR?(text)
            }


        request.recognitionLevel =
            .fast

        request.usesLanguageCorrection =
            false


        if #available(iOS 18.0, *) {

            request.recognitionLanguages =
                [
                    "ja-JP",
                    "en-US"
                ]
        }


        let handler =
            VNImageRequestHandler(
                cvPixelBuffer:
                    pixelBuffer,
                orientation:
                    .up,
                options:
                    [:]
            )


        do {

            try handler.perform(
                [request]
            )

        } catch {

            // OCR失敗で画面取得自体は止めない
        }
    }


    // =========================================================
    // プライバシーモード
    // =========================================================

    func pauseAnalysis() {

        privacyPaused =
            true
    }


    func resumeAnalysis() {

        privacyPaused =
            false
    }


    // =========================================================
    // 停止
    // =========================================================

    func stop() {

        Task {

            if let stream {

                try? await
                    stream.stopCapture()
            }

            self.stream =
                nil

            self.onStatus?(
                "画面取得：停止中"
            )
        }
    }


    // =========================================================
    // Streamエラー
    // =========================================================

    func stream(
        _ stream: SCStream,
        didStopWithError error: any Error
    ) {

        onStatus?(
            "画面取得が停止しました：\(error.localizedDescription)"
        )
    }
}
