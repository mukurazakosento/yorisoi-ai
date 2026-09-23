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

    // 連続一致回数
    private var keywordMatchCount: Int = 0

    // 最後にステップが進んだ時刻
    private var lastProgressDate: Date = Date()

    // 再通知回数
    private var reminderCount: Int = 0

    // 再通知間隔
    private let reminderInterval: TimeInterval = 10

    // 連続一致が必要な回数
    private let requiredConsecutiveMatches: Int = 2

    // 通知直後のOCR誤判定防止
    private var notificationIgnoreUntil: Date = .distantPast

    private let notificationIgnoreInterval: TimeInterval = 4

    // MARK: - Init

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

                guard let self else {
                    return
                }

                self.captureStatus = "画面解析中"

                if !self.plan.isEmpty {
                    await self.sendCurrentInstruction()
                }
            }
        }

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

        // ---------------------------------------------
        // Teams専用の支援プランを作成
        // ---------------------------------------------

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

        // 初期化
        currentStepIndex = 0
        keywordMatchCount = 0
        reminderCount = 0
        lastProgressDate = Date()

        currentInstruction =
            plan[0].message

        // 通知許可
        let granted =
            await notifications.requestPermission()

        guard granted else {

            notificationStatus =
                "通知OFF"

            isRunning = false

            return
        }

        notificationStatus = "通知ON"

        isRunning = true

        captureStatus =
            "画面取得を開始しています"

        // キャプチャ開始
        capture.startFullDisplayCapture()
    }

    // MARK: - OCR Processing

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

        // ---------------------------------------------
        // 通知そのものをOCRして誤判定しない
        // ---------------------------------------------

        if Date() < notificationIgnoreUntil {

            print(
                "⏸️ 通知直後なのでOCR判定を停止"
            )

            return
        }

        let step =
            plan[currentStepIndex]

        // ---------------------------------------------
        // 手動完了ステップ
        //
        // 最後の送信案内など。
        // 通知を出したら自動判定しない。
        // ---------------------------------------------

        if step.manualFinish {

            print(
                "🛑 手動完了ステップのため自動判定しません"
            )

            return
        }

        let normalizedOCR =
            normalize(text)

        print("================================")
        print("🔎 OCR")
        print(text)
        print("🎯 現在の案内")
        print(step.message)
        print("🔑 検出候補")
        print(step.detectKeywords)
        print("================================")

        // キーワードなし
        if step.detectKeywords.isEmpty {

            checkReminder()

            return
        }

        // ---------------------------------------------
        // 候補文字をチェック
        // ---------------------------------------------

        var matchedKeywords: [String] = []

        for keyword in step.detectKeywords {

            let normalizedKeyword =
                normalize(keyword)

            guard !normalizedKeyword.isEmpty else {
                continue
            }

            if normalizedOCR.contains(
                normalizedKeyword
            ) {

                matchedKeywords.append(
                    keyword
                )
            }
        }

        let matchCount =
            matchedKeywords.count

        print(
            "🔍 一致数: \(matchCount)/\(step.minimumMatches)"
        )

        // ---------------------------------------------
        // 一致
        // ---------------------------------------------

        if matchCount >= step.minimumMatches {

            keywordMatchCount += 1

            print(
                "✅ 画面条件一致 \(keywordMatchCount)/\(requiredConsecutiveMatches)"
            )

            if keywordMatchCount
                >= requiredConsecutiveMatches {

                keywordMatchCount = 0
                reminderCount = 0
                lastProgressDate = Date()

                advanceToNextStep()
            }

        }

        // ---------------------------------------------
        // 不一致
        // ---------------------------------------------

        else {

            keywordMatchCount = 0

            print(
                "❌ 画面条件不一致"
            )

            checkReminder()
        }
    }

    // MARK: - Advance

    private func advanceToNextStep() {

        currentStepIndex += 1

        // ---------------------------------------------
        // 全ステップ完了
        // ---------------------------------------------

        if currentStepIndex >= plan.count {

            finishSupport()

            return
        }

        keywordMatchCount = 0
        reminderCount = 0
        lastProgressDate = Date()

        currentInstruction =
            plan[currentStepIndex].message

        Task { @MainActor in
            await sendCurrentInstruction()
        }
    }

    // MARK: - Send Current Instruction

    private func sendCurrentInstruction() async {

        guard currentStepIndex < plan.count else {
            return
        }

        let step =
            plan[currentStepIndex]

        currentInstruction =
            step.message

        notificationIgnoreUntil =
            Date().addingTimeInterval(
                notificationIgnoreInterval
            )

        lastProgressDate =
            Date()

        notificationStatus =
            "案内を送信中"

        await notifications.send(
            title: "よりそいAI",
            body: step.message
        )

        notificationStatus =
            "通知送信済み"

        print(
            "📣 通知: \(step.message)"
        )

        // ---------------------------------------------
        // 最後の送信ステップ
        //
        // ここで支援を終了。
        // OCRが「送信」を拾って勝手に
        // ミッション達成しないようにする。
        // ---------------------------------------------

        if step.manualFinish {

            isRunning = false

            captureStatus =
                "送信操作を待っています"

            print(
                "🛑 最終案内を送信。自動判定を終了"
            )
        }
    }

    // MARK: - Reminder

    private func checkReminder() {

        guard isRunning else {
            return
        }

        guard currentStepIndex < plan.count else {
            return
        }

        let step =
            plan[currentStepIndex]

        // 手動完了ステップには再通知しない
        if step.manualFinish {
            return
        }

        // 通知直後は再通知しない
        if Date() < notificationIgnoreUntil {
            return
        }

        let now =
            Date()

        guard now.timeIntervalSince(
            lastProgressDate
        ) >= reminderInterval else {
            return
        }

        // 1ステップ最大2回
        guard reminderCount < 2 else {
            return
        }

        reminderCount += 1
        lastProgressDate = now

        notificationIgnoreUntil =
            Date().addingTimeInterval(
                notificationIgnoreInterval
            )

        Task { @MainActor in

            await self.notifications.send(
                title: "よりそいAI",
                body:
                    "もう一度ご案内します。\n\(step.message)"
            )

            self.notificationStatus =
                "案内を再通知しました"

            print(
                "🔁 再通知 \(self.reminderCount)/2"
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

        notificationIgnoreUntil =
            .distantFuture

        Task { @MainActor in

            await notifications.send(
                title: "よりそいAI",
                body: "支援が完了しました。"
            )
        }

        print(
            "🎉 支援完了"
        )
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
                        "Teamsでメッセージを送るお手伝い"
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
                            "例：田中さん",
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
                        .lineLimit(
                            3...6
                        )
                        .textFieldStyle(
                            .roundedBorder
                        )
                    }
                    .padding(.horizontal)

                    // -----------------------------------------
                    // スタート
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
                            ? "まだありません"
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
                            maxHeight: 180
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
