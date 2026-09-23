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

    // 画面フレームを受け取るキュー
    private let captureQueue = DispatchQueue(
        label: "yorisoi.capture.queue",
        qos: .userInitiated
    )

    // OCR処理専用キュー
    // シリアルにして、OCRが重なりすぎないようにする
    private let visionQueue = DispatchQueue(
        label: "yorisoi.vision.queue",
        qos: .userInitiated
    )

    // OCR実行間隔
    private var lastOCRTime: Date = .distantPast

    private let ocrInterval: TimeInterval = 0.8

    // MARK: - Init

    override init() {
        super.init()

        // システムの画面共有ピッカーに自分を登録
        picker.addObserver(self)

        // 全画面を選択するようにする
        var configuration = SCContentSharingPickerConfiguration()

        configuration.allowedPickerModes =
            .singleDisplay

        // 今回はアプリ自身のカメラ・マイクは使わない
        configuration.showsCameraControl = false
        configuration.showsMicrophoneControl = false

        // 選択対象をあとから変更できるようにする
        configuration.allowsChangingSelectedContent = true

        picker.defaultConfiguration = configuration

        print("✅ ScreenCaptureCoordinator 初期化")
    }

    deinit {
        picker.removeObserver(self)
        print("🛑 ScreenCaptureCoordinator 解放")
    }

    // MARK: - Start

    func startFullDisplayCapture() {

        DispatchQueue.main.async { [weak self] in

            guard let self else {
                return
            }

            // すでに動いている場合は二重起動しない
            if self.stream != nil {
                self.onStatus?("⚠️ 画面キャプチャはすでに動いています")
                return
            }

            self.onStatus?("📱 画面共有を準備しています")

            // iOSのシステム画面共有ピッカーを表示
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
    //
    // ユーザーがシステム画面共有ピッカーで
    // 「画面全体」を選択するとここに来る
    //

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {

        print("✅ 画面共有対象が選択されました")

        onStatus?("✅ 画面共有対象を取得しました")

        // 以前のストリームがあれば停止
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

        // 新しいストリームを開始
        startStream(with: filter)
    }

    // MARK: - Picker Cancel

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {

        print("ℹ️ 画面共有がキャンセルされました")

        onStatus?("画面共有がキャンセルされました")
    }

    // MARK: - Picker Error

    func contentSharingPickerStartDidFailWithError(
        _ error: any Error
    ) {

        print(
            "❌ 画面共有開始エラー: \(error.localizedDescription)"
        )

        onStatus?(
            "⚠️ 画面共有開始エラー: \(error.localizedDescription)"
        )
    }

    // MARK: - Create Stream

    private func startStream(
        with filter: SCContentFilter
    ) {

        // ScreenCaptureKitのストリーム設定
        let configuration = SCStreamConfiguration()

        // Vision OCRで扱いやすいBGRA
        configuration.pixelFormat =
            kCVPixelFormatType_32BGRA

        // 画面全体をそのまま取得
        //
        // iOS 27のScreenCaptureKitでは、
        // 必要以上に解像度を固定せず、
        // システム側のデフォルトを利用する。
        //
        // width / heightを固定すると、
        // iPhoneの機種によっては画面比率や文字サイズに
        // 不利になる場合があるため、今は設定しない。

        let newStream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: self
        )

        do {

            // 画面フレームを受け取る
            try newStream.addStreamOutput(
                self,
                type: .screen,
                sampleHandlerQueue: captureQueue
            )

            self.stream = newStream

            print("✅ SCStream作成成功")
            print("▶️ 画面キャプチャを開始します")

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

            onStatus?(
                "❌ 画面出力設定エラー: \(error.localizedDescription)"
            )

            self.stream = nil
        }
    }

    // MARK: - SCStreamOutput
    //
    // ScreenCaptureKitから画面フレームが届く
    //

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {

        // 今回必要なのは画面だけ
        guard type == .screen else {
            return
        }

        // サンプルバッファが有効か確認
        guard sampleBuffer.isValid else {
            return
        }

        // 画像を取得
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

        // OCRを0.8秒間隔で実行
        //
        // ScreenCaptureKitはもっと多くのフレームを
        // 送ってくる可能性があるが、
        // 全フレームをOCRすると負荷が高すぎるため
        // 0.8秒に1回程度にする。
        guard now.timeIntervalSince(lastOCRTime)
                >= ocrInterval
        else {
            return
        }

        lastOCRTime = now

        // OCR処理へ渡す
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

            // 結果を取得
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
                recognizedTexts.joined(separator: "\n")

            DispatchQueue.main.async {

                if text.isEmpty {

                    self.onStatus?(
                        "⚠️ 画面は取得できていますが、OCRで文字を認識できません"
                    )

                    print(
                        "⚠️ OCR結果: 文字なし"
                    )

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

        // 高精度認識
        //
        // 速度よりも文字認識の精度を優先する。
        request.recognitionLevel = .accurate

        // 日本語を優先し、英語も認識
        request.recognitionLanguages = [
            "ja-JP",
            "en-US"
        ]

        // 言語補正
        request.usesLanguageCorrection = true

        // このアプリで頻繁に出る単語
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

        // 小さすぎる文字を少し除外
        //
        // 画面全体のノイズを減らす。
        request.minimumTextHeight = 0.012

        // Visionへ画像を渡す
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
