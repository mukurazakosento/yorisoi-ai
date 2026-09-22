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

    init() {
        capture.onOCR = { [weak self] text in
            Task { @MainActor in
                self?.processOCR(text)
            }
        }

        capture.onStatus = { [weak self] text in
            Task { @MainActor in
                self?.captureStatus = text
            }
        }
    }

    func start() {
        Task {
            await startAsync()
        }
    }

    private func startAsync() async {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            status = "「したいこと」を入力してください。"
            return
        }

        steps = planner.plan(for: text)
        stepIndex = 0

        let permission = await notifications.requestPermission()
        notificationStatus = permission
            ? "通知：許可済み"
            : "通知：未許可"

        guard permission else {
            status = "通知を許可してください。"
            return
        }

        do {
            status = "iPhoneの画面共有を選択してください。"
            try await capture.startFullDisplayCapture()

            isRunning = true
            status = "準備完了。ホーム画面へ戻ってください。"

            sendCurrentInstruction()

        } catch {
            status = "画面共有を開始できませんでした。"
            isRunning = false
        }
    }

    func stop() {
        capture.stop()
        isRunning = false
        status = "停止しました。"
        captureStatus = "画面取得：停止中"
    }

    private func processOCR(_ text: String) {
        lastOCR = text

        guard isRunning else { return }
        guard stepIndex < steps.count else { return }

        // 個人情報入力が疑われる画面では解析を一時停止。
        if PrivacyGuard.isSensitive(text) {
            capture.pauseAnalysis()

            Task {
                await notifications.send(
                    title: "よりそいAI",
                    body: "個人情報を入力する画面です。ここからは画面を解析しません。ご自身で入力してください。"
                )
            }

            status = "🔒 プライバシーモード"
            return
        }

        capture.resumeAnalysis()

        let step = steps[stepIndex]

        // 本番ではここを画像理解AIに置き換える。
        if !step.detectKeyword.isEmpty,
           text.localizedCaseInsensitiveContains(step.detectKeyword) {

            stepIndex += 1

            if stepIndex < steps.count {
                sendCurrentInstruction()
            } else {
                Task {
                    await notifications.send(
                        title: "よりそいAI",
                        body: "ミッション達成です。お疲れさまでした。"
                    )
                }
                status = "ミッション達成"
                capture.pauseAnalysis()
            }
        }
    }

    private func sendCurrentInstruction() {
        guard stepIndex < steps.count else { return }

        let step = steps[stepIndex]

        Task {
            await notifications.send(
                title: "よりそいAI",
                body: step.message
            )
        }

        status = "案内中：\(step.message)"
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: SupportModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("よりそいAI")
                .font(.system(size: 38, weight: .bold))

            Text("スマホで、したいことを入力してください")
                .foregroundStyle(.secondary)

            HStack {
                TextField("例：孫に写真を送りたい", text: $model.request)
                    .textFieldStyle(.roundedBorder)

                Button("開始") {
                    model.start()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isRunning)
            }

            VStack(alignment: .leading, spacing: 10) {
                Label(model.status, systemImage: "sparkles")
                Label(model.captureStatus, systemImage: "rectangle.inset.filled.and.person.filled")
                Label(model.notificationStatus, systemImage: "bell")

                if !model.lastOCR.isEmpty {
                    Text("直近のOCR：\(model.lastOCR.prefix(180))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))

            if model.isRunning {
                Button("支援を停止") {
                    model.stop()
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }

            Text("この版はiOS 27+のScreenCaptureKitを使う実証プロトタイプです。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(24)
    }
}
