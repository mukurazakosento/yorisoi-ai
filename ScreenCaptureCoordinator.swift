import Foundation
import ScreenCaptureKit
import Vision
import CoreMedia
import CoreVideo
import UIKit

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

    // 画面フレーム受信用
    private let captureQueue = DispatchQueue(
        label: "yorisoi.capture.queue",
        qos: .userInitiated
    )

    // OCR処理用
    private let visionQueue = DispatchQueue(
        label: "yorisoi.vision.queue",
        qos: .userInitiated
    )

    // OCR実行時刻
    private var lastOCRTime: Date = .distantPast

    // OCR間隔
    private let ocrInterval: TimeInterval = 0.8

    // MARK: - Init

    override init() {
        super.init()

        // iOS 27のAPI
        picker.add(self)

        // iOSでは追加のPicker設定を行わず、
        // システムの標準設定を利用する
        picker.defaultConfiguration =
            SCContentSharingPickerConfiguration()

        print("✅ ScreenCaptureCoordinator 初期化")
    }

    deinit {
        picker.remove(self)
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

            // iOSのシステム画面共有ピッカー
            self.picker.present()

            print("📱 SCContentSharingPicker を表示")
        }
    }

    // MARK: - Stop

    func stop() {

        guard let stream else {
            onStatus?("待機中")
            return
        }

        self.stream = nil

        Task {

            do {

                try await stream.stopCapture()

                await MainActor.run {
                    self.onStatus?("停止しました")
                }

                print("🛑 画面キャプチャ停止")

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

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {

        print("✅ 画面共有対象が選択されました")

        DispatchQueue.main.async { [weak self] in
            self?.onStatus?(
                "✅ 画面共有対象を取得しました"
            )
        }

        // 古いストリームを停止
        if let oldStream = self.stream {

            Task {

                do {
                    try await oldStream.stopCapture()
                } catch {
                    print(
                        "⚠️ 古いストリーム停止エラー: \(error.localizedDescription)"
                    )
                }
            }

            self.stream = nil
        }

        // 新しいストリーム開始
        startStream(with: filter)
    }

    // MARK: - Picker Cancel

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {

        print("ℹ️ 画面共有がキャンセルされました")

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
            "❌ 画面共有開始エラー: \(error.localizedDescription)"
        )

        DispatchQueue.main.async { [weak self] in
            self?.onStatus?(
                "⚠️ 画面共有開始エラー: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Create Stream

    private func startStream(
        with filter: SCContentFilter
    ) {

        // iOSではMac専用の
        // pixelFormat / queueDepth / minimumFrameInterval
        // などは設定しない

        let configuration = SCStreamConfiguration()

        let newStream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: self
        )

        do {

            try newStream.addStreamOutput(
                self,
                type: .screen,
                sampleHandlerQueue: captureQueue
            )

            self.stream = newStream

            print("✅ SCStream作成成功")
            print("▶️ 画面キャプチャを開始します")

            DispatchQueue.main.async { [weak self] in
                self?.onStatus?(
                    "画面キャプチャを開始しています"
                )
            }

            Task {

                do {

                    try await newStream.startCapture()

                    await MainActor.run {

                        self.onStatus?(
                            "✅ 画面キャプチャ中"
                        )

                        self.onCaptureStarted?()
                    }

                    print("✅ SCStream開始成功")

                } catch {

                    await MainActor.run {

                        self.onStatus?(
                            "❌ キャプチャ開始失敗: \(error.localizedDescription)"
                        )
                    }

                    print(
                        "❌ startCaptureエラー: \(error.localizedDescription)"
                    )

                    self.stream = nil
                }
            }

        } catch {

            print(
                "❌ addStreamOutputエラー: \(error.localizedDescription)"
            )

            DispatchQueue.main.async { [weak self] in
                self?.onStatus?(
                    "❌ 画面出力設定エラー: \(error.localizedDescription)"
                )
            }

            self.stream = nil
        }
    }

    // MARK: - SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {

        // 画面のみ処理
        guard type == .screen else {
            return
        }

        // サンプルバッファ確認
        guard sampleBuffer.isValid else {
            return
        }

        // 画像取得
        guard let pixelBuffer =
                CMSampleBufferGetImageBuffer(sampleBuffer)
        else {

            DispatchQueue.main.async { [weak self] in
                self?.onStatus?(
                    "⚠️ 画面画像を取得できません"
                )
            }

            return
        }

        let now = Date()

        // OCRしすぎない
        guard now.timeIntervalSince(lastOCRTime)
                >= ocrInterval
        else {
            return
        }

        lastOCRTime = now

        // OCRを別キューで実行
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

            // OCRエラー
            if let error {

                DispatchQueue.main.async {

                    self.onStatus?(
                        "⚠️ OCRエラー: \(error.localizedDescription)"
                    )
                }

                print(
                    "❌ Vision OCRエラー: \(error.localizedDescription)"
                )

                return
            }

            // OCR結果
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

                recognizedTexts.append(value)
            }

            let text =
                recognizedTexts.joined(
                    separator: "\n"
                )

            DispatchQueue.main.async {

                if text.isEmpty {

                    self.onStatus?(
                        "⚠️ 画面は取得できていますが、OCRで文字を認識できません"
                    )

                    print("⚠️ OCR結果: 文字なし")

                } else {

                    self.onStatus?(
                        "✅ OCR成功（\(recognizedTexts.count)項目）"
                    )

                    print("🔎 OCR結果:")
                    print(text)

                    self.onOCR?(text)
                }
            }
        }

        // 高精度OCR
        request.recognitionLevel = .accurate

        // 日本語 + 英語
        request.recognitionLanguages = [
            "ja-JP",
            "en-US"
        ]

        // 言語補正
        request.usesLanguageCorrection = true

        // このアプリでよく登場する言葉
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
        request.minimumTextHeight = 0.012

        // Visionへ渡す
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .up,
            options: [:]
        )

        do {

            try handler.perform([
                request
            ])

        } catch {

            DispatchQueue.main.async { [weak self] in

                self?.onStatus?(
                    "⚠️ OCR実行エラー: \(error.localizedDescription)"
                )
            }

            print(
                "❌ VNImageRequestHandlerエラー: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - SCStreamDelegate

    func streamDidBecomeActive(
        _ stream: SCStream
    ) {

        print("🟢 SCStream Active")

        DispatchQueue.main.async { [weak self] in

            self?.onStatus?(
                "🟢 画面キャプチャが有効です"
            )
        }
    }

    func streamDidBecomeInactive(
        _ stream: SCStream
    ) {

        print("🟡 SCStream Inactive")

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
