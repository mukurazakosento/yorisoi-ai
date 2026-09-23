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

    // 同じ画面を連続して確認した回数
    private var screenMatchCount: Int = 0

    // 通知直後は、その通知自体をOCRで拾わない
    private var notificationIgnoreUntil: Date = .distantPast

    private let notificationIgnoreInterval: TimeInterval = 5

    // 2回連続で同じ画面条件を確認したら次へ
    private let requiredStableMatches: Int = 2

    // MARK: - Init

    init() {

        capture.onOCR = { [weak self] text in
            Task { @MainActor [weak self] in
                self?.processOCR(text)
            }
        }

        capture.onStatus = { [weak self] status in
            Task { @MainActor [weak self] in
                self?.captureStatus = status
            }
        }

        capture.onCaptureStarted = { [weak self] in
            Task { @MainActor [weak self] in

                guard let self else {
                    return
                }

                self.captureStatus = "画面を確認しています"

                // ここでは通知しない
                // 最初の画面を実際に確認してから通知する
                print("🔍 キャプチャ開始。画面確認を開始")
            }
        }

        Task { @MainActor [weak self] in
            await self?.checkNotificationStatus()
        }
    }

    // MARK: - Notification Status

    private func checkNotificationStatus() async {

        let granted = await notifications.requestPermission()

        if granted {
            notificationStatus = "通知ON"
        } else {
            notificationStatus = "通知OFF"
        }
    }

    // MARK: - Start

    func start() {

        let cleanRecipient = recipient.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        let cleanMessage = message.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !cleanRecipient.isEmpty else {
            notificationStatus = "送る相手を入力してください"
            return
        }

        guard !cleanMessage.isEmpty else {
            notificationStatus = "送る文章を入力してください"
            return
        }

        Task { @MainActor [weak self] in

            guard let self else {
                return
            }

            await self.startAsync(
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

        plan = planner.makePlan(
            recipient: recipient,
            message: message
        )

        guard !plan.isEmpty else {
            notificationStatus = "支援内容を作成できませんでした"
            return
        }

        currentStepIndex = 0
        screenMatchCount = 0
        currentInstruction = ""

        notificationIgnoreUntil = .distantPast

        let granted = await notifications.requestPermission()

        guard granted else {
            notificationStatus = "通知OFF"
            isRunning = false
            return
        }

        notificationStatus = "通知ON"
        isRunning = true
        captureStatus = "画面を確認しています"

        capture.startFullDisplayCapture()
    }

    // MARK: - OCR Processing

    private func processOCR(_ text: String) {

        guard isRunning else {
            return
        }

        guard currentStepIndex < plan.count else {
            return
        }

        // 最後の送信案内など
        // 手動終了ステップに入っていたら何もしない
        let step = plan[currentStepIndex]

        if step.manualFinish {
            print("🛑 最終ステップのため自動判定しません")
            return
        }

        // 通知直後は判定しない
        if Date() < notificationIgnoreUntil {
            print("⏸️ 通知直後のためOCR判定を停止")
            return
        }

        lastOCR = text

        let normalizedOCR = normalize(text)

        guard !normalizedOCR.isEmpty else {
            print("⏸️ OCR結果が空なので通知しません")
            return
        }

        print("================================")
        print("🔍 現在のステップ: \(currentStepIndex)")
        print("📺 OCR:")
        print(text)
        print("🎯 条件:")
        print(step.detectKeywords)
        print("================================")

        let matchCount = countMatches(
            ocr: normalizedOCR,
            keywords: step.detectKeywords
        )

        print(
            "🔎 画面条件一致: \(matchCount)/\(step.minimumMatches)"
        )

        // 条件不一致
        guard matchCount >= step.minimumMatches else {

            screenMatchCount = 0

            captureStatus =
                "画面を確認中"

            print("❌ 画面条件不一致 → 通知しません")

            return
        }

        // 条件一致
        screenMatchCount += 1

        captureStatus =
            "画面条件を確認中 \(screenMatchCount)/\(requiredStableMatches)"

        print(
            "✅ 画面条件一致 \(screenMatchCount)/\(requiredStableMatches)"
        )

        // まだ2回確認していない
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

            let normalizedKeyword = normalize(keyword)

            guard !normalizedKeyword.isEmpty else {
                continue
            }

            if ocr.contains(normalizedKeyword) {
                count += 1
            }
        }

        return count
    }

    // MARK: - Advance

    private func advanceToNextStep() {

        currentStepIndex += 1

        guard currentStepIndex < plan.count else {

            finishSupport()

            return
        }

        screenMatchCount = 0

        currentInstruction =
            plan[currentStepIndex].message

        Task { @MainActor [weak self] in

            guard let self else {
                return
            }

            await self.sendCurrentInstruction()
        }
    }

    // MARK: - Send Instruction

    private func sendCurrentInstruction() async {

        guard currentStepIndex < plan.count else {
            return
        }

        let step = plan[currentStepIndex]

        currentInstruction = step.message

        // 通知直後のOCRを無視
        notificationIgnoreUntil =
            Date().addingTimeInterval(
                notificationIgnoreInterval
            )

        notificationStatus = "案内を送信中"

        await notifications.send(
            title: "よりそいAI",
            body: step.message
        )

        notificationStatus = "通知送信済み"

        print("📣 通知:")
        print(step.message)

        // 最終ステップならここで自動判定終了
        if step.manualFinish {

            isRunning = false

            captureStatus =
                "送信ボタンを押してください"

            print(
                "🛑 最終案内。自動判定終了"
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

        print("🎉 支援完了")
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

                    // MARK: 相手

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

                    // MARK: 文章

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

                    // MARK: 開始

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

                    // MARK: 状態

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
            .navigationTitle("よりそいAI")
        }
    }
}
