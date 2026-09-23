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

    @Published var goal: String = ""
    @Published var isRunning: Bool = false

    @Published var captureStatus: String = "待機中"
    @Published var lastOCR: String = ""
    @Published var notificationStatus: String = "通知確認中"

    private let capture = ScreenCaptureCoordinator()
    private let notifications = NotificationCoordinator()
    private let planner = InstructionPlanner()

    private var plan: [InstructionStep] = []
    private var currentStepIndex: Int = 0

    // 現在のステップがOCRで何回連続一致したか
    private var keywordMatchCount: Int = 0

    // 最後にステップが進んだ時刻
    private var lastProgressDate: Date = Date()

    // 現在のステップを再通知した回数
    private var reminderCount: Int = 0

    // 再通知までの時間
    private let reminderInterval: TimeInterval = 8

    // 連続一致が必要な回数
    private let requiredMatchCount: Int = 2

    init() {

        // OCRを受け取った時
        capture.onOCR = { [weak self] text in
            Task { @MainActor in
                self?.processOCR(text)
            }
        }

        // キャプチャ状態が変わった時
        capture.onStatus = { [weak self] status in
            Task { @MainActor in
                self?.captureStatus = status
            }
        }

        // 画面キャプチャ開始成功
        capture.onCaptureStarted = { [weak self] in
            Task { @MainActor in
                guard let self else { return }

                self.captureStatus = "画面解析中"

                // 最初の案内をすぐ通知
                if !self.plan.isEmpty {
                    await self.sendCurrentInstruction()
                }
            }
        }

        // 通知状態を確認
        Task { @MainActor in
            await self.checkNotificationStatus()
        }
    }

    // MARK: - Notification

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

        let trimmedGoal = goal.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !trimmedGoal.isEmpty else {
            notificationStatus = "やりたいことを入力してください"
            return
        }

        Task { @MainActor in
            await startAsync()
        }
    }

    private func startAsync() async {

        // 支援プランを作成
        plan = planner.makePlan(for: goal)

        guard !plan.isEmpty else {
            notificationStatus = "支援内容を作成できませんでした"
            return
        }

        // 初期化
        currentStepIndex = 0
        keywordMatchCount = 0
        reminderCount = 0
        lastProgressDate = Date()

        // 通知権限を確認
        let granted = await notifications.requestPermission()

        guard granted else {
            notificationStatus = "通知OFF"
            isRunning = false
            return
        }

        notificationStatus = "通知ON"
        isRunning = true
        captureStatus = "画面取得を開始しています"

        // 画面キャプチャ開始
        capture.startFullDisplayCapture()
    }

    // MARK: - OCR Processing

    private func processOCR(_ text: String) {

        guard isRunning else {
            return
        }

        lastOCR = text

        guard currentStepIndex < plan.count else {
            return
        }

        let step = plan[currentStepIndex]

        let normalizedOCR = normalize(text)
        let normalizedKeyword = normalize(step.detectKeyword)

        print("================================")
        print("🔎 OCR:")
        print(text)
        print("🎯 現在のステップ:")
        print(step.message)
        print("🔑 判定キーワード:")
        print(step.detectKeyword)
        print("================================")

        // キーワードが設定されていない場合
        guard !normalizedKeyword.isEmpty else {
            checkReminder()
            return
        }

        // OCR文字列の中にキーワードがあるか
        let matched = normalizedOCR.contains(normalizedKeyword)

        if matched {

            keywordMatchCount += 1

            print(
                "✅ キーワード一致: \(keywordMatchCount)/\(requiredMatchCount)"
            )

            // 2回連続一致で次へ
            if keywordMatchCount >= requiredMatchCount {

                keywordMatchCount = 0
                reminderCount = 0
                lastProgressDate = Date()

                advanceToNextStep()
            }

        } else {

            // 一致しなければ連続一致をリセット
            keywordMatchCount = 0

            print("❌ キーワード不一致")

            // 一定時間進まなければ再通知
            checkReminder()
        }
    }

    // MARK: - Advance

    private func advanceToNextStep() {

        currentStepIndex += 1

        // すべて完了
        if currentStepIndex >= plan.count {

            isRunning = false

            capture.stop()

            captureStatus = "支援完了"

            Task { @MainActor in
                await notifications.send(
                    title: "よりそいAI",
                    body: "ミッション達成です。お疲れさまでした。"
                )
            }

            print("🎉 ミッション達成")
            return
        }

        // 次のステップの時間を更新
        lastProgressDate = Date()
        reminderCount = 0
        keywordMatchCount = 0

        // 次の案内
        Task { @MainActor in
            await sendCurrentInstruction()
        }
    }

    // MARK: - Send Current Instruction

    private func sendCurrentInstruction() async {

        guard currentStepIndex < plan.count else {
            return
        }

        let step = plan[currentStepIndex]

        notificationStatus = "案内を送信中"

        await notifications.send(
            title: "よりそいAI",
            body: step.message
        )

        notificationStatus = "通知送信済み"

        print("📣 案内通知:")
        print(step.message)
    }

    // MARK: - Reminder

    private func checkReminder() {

        guard isRunning else {
            return
        }

        guard currentStepIndex < plan.count else {
            return
        }

        let now = Date()

        // 8秒経過していない場合は何もしない
        guard now.timeIntervalSince(lastProgressDate)
                >= reminderInterval else {
            return
        }

        // 1ステップ最大3回まで再通知
        guard reminderCount < 3 else {
            return
        }

        reminderCount += 1
        lastProgressDate = now

        Task { @MainActor in

            guard self.currentStepIndex < self.plan.count else {
                return
            }

            let step = self.plan[self.currentStepIndex]

            await self.notifications.send(
                title: "よりそいAI",
                body: "もう一度ご案内します。\n\(step.message)"
            )

            self.notificationStatus = "案内を再通知しました"

            print(
                "🔁 再通知 \(self.reminderCount)/3"
            )

            print(step.message)
        }
    }

    // MARK: - Normalize OCR

    private func normalize(_ text: String) -> String {

        let lowercased = text.lowercased()

        let ignoredCharacters = CharacterSet(
            charactersIn:
                " \n\r\t　。、．，！？!?.,:：;；「」『』（）()[]［］【】"
        )

        let scalars = lowercased.unicodeScalars.filter {
            !ignoredCharacters.contains($0)
        }

        return String(
            String.UnicodeScalarView(scalars)
        )
    }
}

// MARK: - Content View

struct ContentView: View {

    @EnvironmentObject var model: SupportModel

    var body: some View {

        NavigationStack {

            VStack(spacing: 20) {

                Text("よりそいAI")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("スマートフォン操作をお手伝いします")
                    .foregroundStyle(.secondary)

                TextField(
                    "例：孫に写真を送りたい",
                    text: $model.goal
                )
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

                Button {

                    model.start()

                } label: {

                    Text(
                        model.isRunning
                        ? "支援中"
                        : "支援を開始"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)

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
                    .frame(maxHeight: 180)
                }
                .padding()
                .frame(
                    maxWidth: .infinity,
                    alignment: .leading
                )

                Spacer()
            }
            .padding(.top)
            .navigationTitle("よりそいAI")
        }
    }
}
