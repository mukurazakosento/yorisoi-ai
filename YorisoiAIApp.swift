import SwiftUI
import UserNotifications

@main
struct YorisoiAIApp: App {

    @StateObject private var model = SupportModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
    }
}

@MainActor
final class SupportModel: ObservableObject {

    @Published var request = "孫に写真を送りたい"
    @Published var status = "待機中"
    @Published var notificationStatus = "通知：未許可"
    @Published var captureStatus = "画面取得：停止中"
    @Published var isRunning = false
    @Published var lastOCR = ""

    let capture = ScreenCaptureCoordinator()
    let notifications = NotificationCoordinator()
    let planner = InstructionPlanner()

    private var steps: [InstructionStep] = []
    private var stepIndex = 0

    // 同じ条件を連続して確認した回数
    private var keywordMatchCount = 0

    // 画面が変わったかを確認するためのOCR
    private var previousOCR = ""

    // MARK: - Init

    init() {

        // OCR
        capture.onOCR = { [weak self] text in

            Task { @MainActor in
                self?.processOCR(text)
            }
        }

        // キャプチャ状態
        capture.onStatus = { [weak self] text in

            Task { @MainActor in
                self?.captureStatus = text
            }
        }

        // 実際に画面キャプチャが始まった瞬間
        capture.onCaptureStarted = { [weak self] in

            Task { @MainActor in

                guard let self else {
                    return
                }

                guard self.isRunning else {
                    return
                }

                self.status =
                    "画面を確認しています。ホーム画面へ戻ってください。"

                // ここでは即通知しない
                // OCRで現在の画面を確認してから案内する
                print("✅ 画面キャプチャ開始")
                print("⏳ 現在の画面を確認中")
            }
        }
    }

    // MARK: - Start

    func start() {

        Task {
            await startAsync()
        }
    }

    private func startAsync() async {

        let text = request
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard !text.isEmpty else {

            status =
                "「したいこと」を入力してください。"

            return
        }

        // 手順作成
        steps = planner.plan(for: text)

        stepIndex = 0

        keywordMatchCount = 0
        previousOCR = ""

        print("🧭 手順数: \(steps.count)")

        for (index, step) in steps.enumerated() {

            print("----- 手順 \(index + 1) -----")
            print("案内: \(step.message)")
            print("検出文字: \(step.detectKeyword)")
        }

        // 通知許可
        let permission =
            await notifications.requestPermission()

        notificationStatus = permission
            ? "通知：許可済み"
            : "通知：未許可"

        guard permission else {

            status =
                "通知を許可してください。"

            return
        }

        do {

            status =
                "iPhoneの画面共有を選択してください。"

            try await capture.startFullDisplayCapture()

            isRunning = true

            status =
                "画面共有の許可を待っています。"

        } catch {

            status =
                "画面共有を開始できませんでした。"

            isRunning = false

            print(
                "❌ 画面共有開始エラー: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Stop

    func stop() {

        capture.stop()

        isRunning = false

        status = "停止しました。"

        captureStatus = "画面取得：停止中"

        keywordMatchCount = 0
        previousOCR = ""
    }

    // MARK: - OCR Processing

    private func processOCR(
        _ text: String
    ) {

        guard isRunning else {
            return
        }

        guard stepIndex < steps.count else {
            return
        }

        // OCR結果を画面表示
        lastOCR = text

        print("")
        print("📖 OCR受信")
        print(text)

        // --------------------------------------------------
        // OCRの正規化
        // --------------------------------------------------

        let normalizedOCR =
            normalizeOCR(text)

        print("🧹 正規化OCR")
        print(normalizedOCR)

        // --------------------------------------------------
        // 画面が変わったか確認
        // --------------------------------------------------

        if normalizedOCR != previousOCR {

            previousOCR = normalizedOCR

            print("🔄 OCR内容が更新されました")
        }

        // --------------------------------------------------
        // プライバシー保護
        // --------------------------------------------------

        if PrivacyGuard.isSensitive(text) {

            capture.pauseAnalysis()

            Task {

                await notifications.send(
                    title: "よりそいAI",
                    body:
                        "個人情報を入力する画面です。ここからは画面を解析しません。ご自身で入力してください。"
                )
            }

            status =
                "🔒 プライバシーモード"

            return
        }

        capture.resumeAnalysis()

        // --------------------------------------------------
        // 現在の手順
        // --------------------------------------------------

        let step = steps[stepIndex]

        let keyword =
            normalizeOCR(step.detectKeyword)

        print("")
        print("🎯 現在の手順")
        print(step.message)

        print("🔎 検出キーワード")
        print(keyword)

        guard !keyword.isEmpty else {

            print("⚠️ detectKeyword が空です")

            return
        }

        // --------------------------------------------------
        // キーワード判定
        // --------------------------------------------------

        if normalizedOCR.contains(keyword) {

            keywordMatchCount += 1

            print(
                "✅ キーワード一致 \(keywordMatchCount)/3"
            )

            status =
                "画面確認中：\(keywordMatchCount)/3"

            // 3回連続で確認できたら次へ
            if keywordMatchCount >= 3 {

                print("✅ 画面状態を確定")

                keywordMatchCount = 0

                stepIndex += 1

                if stepIndex < steps.count {

                    sendCurrentInstruction()

                } else {

                    Task {

                        await notifications.send(
                            title: "よりそいAI",
                            body:
                                "ミッション達成です。お疲れさまでした。"
                        )
                    }

                    status =
                        "ミッション達成"

                    capture.pauseAnalysis()
                }
            }

        } else {

            // 一度でも一致しなければ連続カウントをリセット
            if keywordMatchCount > 0 {

                print(
                    "↩️ キーワード不一致 → カウントリセット"
                )
            }

            keywordMatchCount = 0
        }
    }

    // MARK: - Send Instruction

    private func sendCurrentInstruction() {

        guard stepIndex < steps.count else {
            return
        }

        let step = steps[stepIndex]

        print("")
        print("📤 次の案内を送信")
        print(step.message)

        Task {

            await notifications.send(
                title: "よりそいAI",
                body: step.message
            )
        }

        status =
            "案内中：\(step.message)"
    }

    // MARK: - OCR Normalize

    private func normalizeOCR(
        _ text: String
    ) -> String {

        var result = text

        // 改行・空白を削除
        result = result.replacingOccurrences(
            of: "\n",
            with: ""
        )

        result = result.replacingOccurrences(
            of: " ",
            with: ""
        )

        result = result.replacingOccurrences(
            of: "　",
            with: ""
        )

        // よくあるOCR記号ノイズを削除
        let charactersToRemove:
            [Character] = [
                "・",
                "･",
                "「",
                "」",
                "『",
                "』",
                "【",
                "】"
            ]

        for character in charactersToRemove {

            result = result.replacingOccurrences(
                of: String(character),
                with: ""
            )
        }

        return result
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            .lowercased()
    }
}

// MARK: - ContentView

struct ContentView: View {

    @EnvironmentObject private var model: SupportModel

    var body: some View {

        VStack(spacing: 24) {

            Spacer()

            Text("よりそいAI")
                .font(
                    .system(
                        size: 38,
                        weight: .bold
                    )
                )

            Text(
                "スマホで、したいことを入力してください"
            )
            .foregroundStyle(.secondary)

            HStack {

                TextField(
                    "例：孫に写真を送りたい",
                    text: $model.request
                )
                .textFieldStyle(.roundedBorder)

                Button("開始") {

                    model.start()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isRunning)
            }

            VStack(
                alignment: .leading,
                spacing: 10
            ) {

                Label(
                    model.status,
                    systemImage: "sparkles"
                )

                Label(
                    model.captureStatus,
                    systemImage:
                        "rectangle.inset.filled.and.person.filled"
                )

                Label(
                    model.notificationStatus,
                    systemImage: "bell"
                )

                if !model.lastOCR.isEmpty {

                    Text(
                        "直近のOCR：\(model.lastOCR.prefix(180))"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                }
            }
            .frame(
                maxWidth: .infinity,
                alignment: .leading
            )
            .padding()
            .background(
                Color(.secondarySystemBackground)
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 16
                )
            )

            if model.isRunning {

                Button("支援を停止") {

                    model.stop()
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }

            Text(
                "この版はiOS 27+のScreenCaptureKitを使う実証プロトタイプです。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(24)
    }
}
