import SwiftUI

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

// MARK: - Support Model

@MainActor
final class SupportModel: ObservableObject {

    @Published var recipient: String = ""
    @Published var message: String = ""

    @Published var isRunning: Bool = false

    @Published var captureStatus: String = "待機中"
    @Published var lastOCR: String = ""
    @Published var notificationStatus: String = "通知確認中"
    @Published var currentInstruction: String = ""

    private let capture = ScreenCaptureCoordinator()
    private let notifications = NotificationCoordinator()
    private let planner = InstructionPlanner()

    private var plan: [InstructionStep] = []

    private var currentStepIndex: Int = 0

    // 同じ画面条件を連続で確認した回数
    private var screenMatchCount: Int = 0

    // 通知直後のOCR誤判定防止
    private var notificationIgnoreUntil: Date = .distantPast

    private let notificationIgnoreInterval: TimeInterval = 5

    // 画面が同じ状態だと2回確認して初めてOK
    private let requiredStableMatches: Int = 2

    // MARK: - Init

    init() {

        // OCR
        capture.onOCR = { [weak self] text in

            Task { @MainActor in
                self?.processOCR(text)
            }
        }

        // キャプチャ状態
        capture.onStatus = { [weak self] status in

            Task { @MainActor in
                self?.captureStatus = status
            }
        }

        // キャプチャ開始
        capture.onCaptureStarted = { [weak self] in

            Task { @MainActor in

                guard let self else {
                    return
                }

                self.captureStatus =
                    "画面を確認しています"

                // ★ここでは通知を送らない
                // 最初の画面をOCRで確認してから判断する
                print(
                    "🔍 キャプチャ開始。最初の画面確認を待っています"
                )
            }
        }

        // 通知状態
        Task { @MainActor in
            await self.checkNotificationStatus()
        }
    }

    // MARK: - Notification Status

    private func checkNotificationStatus() async {

        let granted =
            await notifications.requestPermission()

        if granted {
            notificationStatus = "通知ON"
        } else {
            notificationStatus = "通知OFF"
        }
    }

    // MARK: - Start

    func start() {

        let cleanRecipient =
            recipient.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        let cleanMessage =
            message.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard !cleanRecipient.isEmpty else {

            notificationStatus =
                "送る相手を入力してください"

            return
        }

        guard !cleanMessage.isEmpty else {

            notificationStatus =
                "送る文章を入力してください"

            return
        }

        Task { @MainActor in

            await startAsync(
                recipient: cleanRecipient,
                message: cleanMessage
            )
        }
    }

    // MARK: - Start Async

    private func startAsync(
        recipient: String,
        message: String
    ) async {

        // Teams専用プラン
        plan =
            planner.makePlan(
                recipient: recipient,
                message: message
            )

        guard !plan.isEmpty else {

            notificationStatus =
                "支援内容を作成できませんでした"

            return
        }

        currentStepIndex = 0
        screenMatchCount = 0

        currentInstruction = ""

        // 通知後の待機状態を解除
        notificationIgnoreUntil =
            .distantPast

        let granted =
            await notifications.requestPermission()

        guard granted else {

            notificationStatus =
                "通知OFF"

            return
        }

        notificationStatus =
            "通知ON"

        isRunning = true

        captureStatus =
            "画面を確認しています"

        // 画面キャプチャ開始
        capture.startFullDisplayCapture()
    }

    // MARK: - OCR

    private func processOCR(
        _ text: String
    ) {

        guard isRunning else {
            return
        }

        lastOCR = text

        guard currentStepIndex < plan.count else {
            return
        }

        // ------------------------------------------------
        // 通知直後は判定しない
        // ------------------------------------------------

        if Date() < notificationIgnoreUntil {

            print(
                "⏸️ 通知直後なので画面判定を待っています"
            )

            return
        }

        let step =
            plan[currentStepIndex]

        // ------------------------------------------------
        // 最終ステップでは自動判定しない
        // ------------------------------------------------

        if step.manualFinish {

            print(
                "🛑 最終ステップ。これ以上自動では進めません"
            )

            return
        }

        let normalizedOCR =
            normalize(text)

        // OCRが空なら何もしない
        guard !normalizedOCR.isEmpty else {

            print(
                "⏸️ OCR文字がないので通知しません"
            )

            return
        }

        print("================================")
        print("🔍 現在のステップ: \(currentStepIndex)")
        print("📺 OCR:")
        print(text)
        print("🎯 次の条件:")
        print(step.detectKeywords)
        print("================================")

        // ------------------------------------------------
        // 画面条件を確認
        // ------------------------------------------------

        let matchCount =
            countMatches(
                ocr: normalizedOCR,
                keywords: step.detectKeywords
            )

        print(
            "🔎 画面条件一致: \(matchCount)/\(step.minimumMatches)"
        )

        // ------------------------------------------------
        // 条件を満たしていない
        //
        // ★通知しない
        // ★再通知もしない
        // ------------------------------------------------

        guard matchCount >= step.minimumMatches else {

            screenMatchCount = 0

            captureStatus =
                "画面を確認中（まだ次の操作ではありません）"

            print(
                "❌ 画面条件不一致 → 通知しません"
            )

            return
        }

        // ------------------------------------------------
        // 条件一致
        // ------------------------------------------------

        screenMatchCount += 1

        captureStatus =
            "画面条件を確認中 \(screenMatchCount)/\(requiredStableMatches)"

        print(
            "✅ 画面条件一致 \(screenMatchCount)/\(requiredStableMatches)"
        )

        // ------------------------------------------------
        // 2回連続一致
        // ------------------------------------------------

        guard screenMatchCount >= requiredStableMatches else {
            return
        }

        // 次へ
        screenMatchCount = 0

        advanceToNextStep()
    }

    // MARK: - Match Count

    private func countMatches(
        ocr: String,
        keywords: [String]
    ) -> Int {

        var count = 0

        for keyword in keywords {

            let normalizedKeyword =
                normalize(keyword)

            guard !normalizedKeyword.isEmpty else {
                continue
            }

            if ocr.contains(
                normalizedKeyword
            ) {

                count += 1
            }
        }

        return count
    }

    // MARK: - Advance

    private func advanceToNextStep() {

        currentStepIndex += 1

        // ---------------------------------------------
        // 全ステップ完了ではなく、
        // 最終案内に入る
        // ---------------------------------------------

        guard currentStepIndex < plan.count else {

            finishSupport()

            return
        }

        let nextStep =
            plan[currentStepIndex]

        currentInstruction =
            nextStep.message

        lastProgressDate()

        Task { @MainActor in {

            await sendCurrentInstruction()
        }}
    }

    // MARK: - Send Instruction

    private func sendCurrentInstruction() async {

        guard currentStepIndex < plan.count else {
            return
        }

        let step =
            plan[currentStepIndex]

        currentInstruction =
            step.message

        // ★通知した直後の画面は判定しない
        notificationIgnoreUntil =
            Date().addingTimeInterval(
                notificationIgnoreInterval
            )

        notificationStatus =
            "案内を送信中"

        await notifications.send(
            title: "よりそいAI",
            body: step.message
        )

        notificationStatus =
            "通知送信済み"

        print(
            "📣 次の画面確認に進むための通知:"
        )

        print(
            step.message
        )

        // ---------------------------------------------
        // 最終案内
        // ---------------------------------------------

        if step.manualFinish {

            isRunning = false

            captureStatus =
                "送信ボタンを押してください"

            print(
                "🛑 最終案内送信。自動判定終了"
            )
        }
    }

    // MARK: - Finish

    private func finishSupport() {

        isRunning = false

        capture.stop()

        currentInstruction =
            "支援が完了しました"

        captureStatus =
            "支援完了"

        print(
            "🎉 支援完了"
        )
    }

    // MARK: - Progress

    private func lastProgressDate() {
        // 今回は「時間が経ったから再通知する」
        // という仕組みを完全に廃止。
        //
        // このメソッドは将来のログ用に残している。
    }

    // MARK: - Normalize

    private func normalize(
        _ text: String
    ) -> String {

        let lowercased =
            text.lowercased()

        let ignoredCharacters =
            CharacterSet(
                charactersIn:
                    " \n\r\t　。、．，！？!?.,:：;；「」『』（）()[]［］【】"
            )

        let scalars =
            lowercased.unicodeScalars.filter {
                !ignoredCharacters.contains($0)
            }

        return String(
            String.UnicodeScalarView(
                scalars
            )
        )
    }
}

// MARK: - Content View

struct ContentView: View {

    @EnvironmentObject var model:
        SupportModel

    var body: some View {

        NavigationStack {

            ScrollView {

                VStack(spacing: 18) {

                    Text("よりそいAI")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text(
                        "Teamsで友達に文章を送るお手伝い"
                    )
                    .foregroundStyle(.secondary)

                    // -----------------------------------------
                    // 相手
                    // -----------------------------------------

                    VStack(
                        alignment: .leading,
                        spacing: 8
                    ) {

                        Text("送る相手")
                            .font(.headline)

                        TextField(
                            "例：山田さん",
                            text: $model.recipient
                        )
                        .textFieldStyle(
                            .roundedBorder
                        )
                    }
                    .padding(.horizontal)

                    // -----------------------------------------
                    // 文章
                    // -----------------------------------------

                    VStack(
                        alignment: .leading,
                        spacing: 8
                    ) {

                        Text("送る文章")
                            .font(.headline)

                        TextField(
                            "例：こんにちは！元気ですか？",
                            text: $model.message,
                            axis: .vertical
                        )
                        .lineLimit(3...6)
                        .textFieldStyle(
                            .roundedBorder
                        )
                    }
                    .padding(.horizontal)

                    // -----------------------------------------
                    // 開始
                    // -----------------------------------------

                    Button {

                        model.start()

                    } label: {

                        Text(
                            model.isRunning
                            ? "支援中"
                            : "支援を開始"
                        )
                        .font(.headline)
                        .frame(
                            maxWidth: .infinity
                        )
                        .padding()
                    }
                    .buttonStyle(
                        .borderedProminent
                    )
                    .padding(.horizontal)

                    // -----------------------------------------
                    // 状態
                    // -----------------------------------------

                    VStack(
                        alignment: .leading,
                        spacing: 10
                    ) {

                        Text("状態")
                            .font(.headline)

                        Text(
                            "支援：\(model.isRunning ? "実行中" : "停止")"
                        )

                        Text(
                            "画面：\(model.captureStatus)"
                        )

                        Text(
                            "通知：\(model.notificationStatus)"
                        )

                        Divider()

                        Text("現在の案内")
                            .font(.headline)

                        Text(
                            model.currentInstruction.isEmpty
                            ? "画面を確認しています"
                            : model.currentInstruction
                        )

                        Divider()

                        Text("最後に認識した画面")
                            .font(.headline)

                        ScrollView {

                            Text(
                                model.lastOCR.isEmpty
                                ? "まだ画面を認識していません"
                                : model.lastOCR
                            )
                            .frame(
                                maxWidth: .infinity,
                                alignment: .leading
                            )
                        }
                        .frame(
                            maxHeight: 200
                        )
                    }
                    .padding()
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                }
                .padding(.top)
            }
            .navigationTitle(
                "よりそいAI"
            )
        }
    }
}
