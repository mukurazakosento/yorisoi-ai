```swift
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

    // 同じステップを何回連続で認識したか
    private var keywordMatchCount: Int = 0

    // 最後にステップが進んだ時刻
    private var lastProgressDate: Date = Date()

    // 再通知した回数
    private var reminderCount: Int = 0

    // 再通知の間隔
    private let reminderInterval: TimeInterval = 8

    // 連続判定回数
    private let requiredMatchCount = 2

    init() {

        capture.onOCR = { [weak self] text in
            Task { @MainActor in
                self?.processOCR(text)
            }
        }

        capture.onStatus = { [weak self] status in
            Task { @MainActor in
                self?.captureStatus = status
            }
        }

        capture.onCaptureStarted = { [weak self] in
            Task { @MainActor in
                guard let self else { return }

                self.captureStatus = "画面解析中"

                // キャプチャ開始直後に最初の案内を通知
                if !self.plan.isEmpty {
                    await self.sendCurrentInstruction()
                }
            }
        }

        Task { @MainActor in
            await checkNotificationStatus()
        }
    }

    // MARK: - 通知状態確認

    private func checkNotificationStatus() async {

        let granted = await notifications.requestPermission()

        if granted {
            notificationStatus = "通知ON"
        } else {
            notificationStatus = "通知OFF"
        }
    }

    // MARK: - 支援開始

    func start() {

        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        Task { @MainActor in
            await startAsync()
        }
    }

    private func startAsync() async {

        // 支援内容を作成
        plan = planner.makePlan(for: goal)

        guard !plan.isEmpty else {
            notificationStatus = "支援内容を作成できませんでした"
            return
        }

        currentStepIndex = 0
        keywordMatchCount = 0
        reminderCount = 0
        lastProgressDate = Date()

        // 通知権限
        let granted = await notifications.requestPermission()

        if granted {
            notificationStatus = "通知ON"
        } else {
            notificationStatus = "通知OFF"
            return
        }

        isRunning = true
        captureStatus = "画面取得を開始しています"

        // 画面キャプチャ開始
        capture.startFullDisplayCapture()
    }

    // MARK: - OCR処理

    private func processOCR(_ text: String) {

        guard isRunning else {
            return
        }

        lastOCR = text

        guard currentStepIndex < plan.count else {
            return
        }

        let step = plan[currentStepIndex]

        // OCRを正規化
        let normalizedOCR = normalize(text)
        let normalizedKeyword = normalize(step.detectKeyword)

        print("🔎 OCR: \(text)")
        print("🎯 現在の案内: \(step.message)")
        print("🔑 判定キーワード: \(step.detectKeyword)")

        // キーワードが空なら、このステップでは自動判定しない
        guard !normalizedKeyword.isEmpty else {
            checkReminder()
            return
        }

        // OCRにキーワードが含まれているか
        let matched = normalizedOCR.contains(normalizedKeyword)

        if matched {

            keywordMatchCount += 1

            print("✅ キーワード一致 \(keywordMatchCount)/\(requiredMatchCount)")

            // 十分な回数一致したら次へ
            if keywordMatchCount >= requiredMatchCount {

                keywordMatchCount = 0
                reminderCount = 0
                lastProgressDate = Date()

                advanceToNextStep()
            }

        } else {

            // 一致しなかったら連続カウントをリセット
            keywordMatchCount = 0

            // 一定時間進まなければ再通知
            checkReminder()
        }
    }

    // MARK: - 次のステップへ

    private func advanceToNextStep() {

        currentStepIndex += 1

        // 全ステップ完了
        if currentStepIndex >= plan.count {

            isRunning = false
            capture.stop()

            Task { @MainActor in
                await notifications.send(
                    title: "よりそいAI",
                    body: "ミッション達成です。お疲れさまでした。"
                )
            }

            captureStatus = "支援完了"

            print("🎉 ミッション達成")
            return
        }

        // 次のステップの通知
        Task { @MainActor in
            await sendCurrentInstruction()
        }
    }

    // MARK: - 現在の案内を通知

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

        print("📣 案内: \(step.message)")
    }

    // MARK: - 再通知

    private func checkReminder() {

        guard isRunning else {
            return
        }

        guard currentStepIndex < plan.count else {
            return
        }

        let now = Date()

        // まだ8秒たっていない
        guard now.timeIntervalSince(lastProgressDate) >= reminderInterval else {
            return
        }

        // 再通知は1ステップにつき最大3回
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

            print("🔁 再通知 \(self.reminderCount)/3: \(step.message)")
        }
    }

    // MARK: - OCR正規化

    private func normalize(_ text: String) -> String {

        let lowercased = text.lowercased()

        let ignoredCharacters = CharacterSet(
            charactersIn:
                " \n\r\t　。、．，！？!?,:：;；「」『』（）()[]［］【】"
        )

        let cleaned = lowercased
            .unicodeScalars
            .filter {
                !ignoredCharacters.contains($0)
            }

        return String(String.UnicodeScalarView(cleaned))
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
                    Text(model.isRunning ? "支援中" : "支援を開始")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 10) {

                    Text("状態")
                        .font(.headline)

                    Text("支援：\(model.isRunning ? "実行中" : "停止")")
                    Text("画面：\(model.captureStatus)")
                    Text("通知：\(model.notificationStatus)")

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
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()
            }
            .padding(.top)
            .navigationTitle("よりそいAI")
        }
    }
}
```
