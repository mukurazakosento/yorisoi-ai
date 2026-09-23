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

    // 支援内容はこれ1つだけ
    @Published var supportContent: String = ""

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

    // 2回確認してから次へ
    private let requiredStableMatches: Int = 2

    // 通知直後の誤判定防止
    private var notificationIgnoreUntil: Date = .distantPast

    private let notificationIgnoreInterval: TimeInterval = 4

    // 同じ案内を連続で送らない
    private var lastNotificationDate: Date = .distantPast

    private let notificationCooldown: TimeInterval = 8

    init() {

        // OCR
        capture.onOCR = { [weak self] text in

            Task { @MainActor [weak self] in

                guard let self else {
                    return
                }

                self.processOCR(text)
            }
        }

        // キャプチャ状態
        capture.onStatus = { [weak self] status in

            Task { @MainActor [weak self] in

                self?.captureStatus = status
            }
        }

        // キャプチャ開始
        capture.onCaptureStarted = { [weak self] in

            Task { @MainActor [weak self] in

                guard let self else {
                    return
                }

                self.captureStatus =
                    "画面を確認しています"

                // ★ここでは通知しない
                // 実際の画面を確認してから通知する
                print(
                    "🔍 キャプチャ開始 → 最初の画面確認"
                )
            }
        }

        // 通知権限
        Task { @MainActor [weak self] in

            guard let self else {
                return
            }

            await self.checkNotificationStatus()
        }
    }

    // MARK: - Notification Status

    private func checkNotificationStatus() async {

        let granted =
            await notifications.requestPermission()

        if granted {

            notificationStatus =
                "通知ON"

        } else {

            notificationStatus =
                "通知OFF"
        }
    }

    // MARK: - Start

    func start() {

        let content =
            supportContent.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard !content.isEmpty else {

            notificationStatus =
                "支援内容を入力してください"

            return
        }

        Task { @MainActor [weak self] in

            guard let self else {
                return
            }

            await self.startAsync(
                supportContent: content
            )
        }
    }

    // MARK: - Start Async

    private func startAsync(
        supportContent: String
    ) async {

        // 支援内容から支援手順を作成
        plan =
            planner.makePlan(
                for: supportContent
            )

        guard !plan.isEmpty else {

            notificationStatus =
                "支援内容を作成できませんでした"

            return
        }

        currentStepIndex = 0
        screenMatchCount = 0
        currentInstruction = ""

        notificationIgnoreUntil =
            .distantPast

        lastNotificationDate =
            .distantPast

        let granted =
            await notifications.requestPermission()

        guard granted else {

            notificationStatus =
                "通知OFF"

            isRunning =
                false

            return
        }

        notificationStatus =
            "通知ON"

        isRunning =
            true

        captureStatus =
            "画面を確認しています"

        print(
            "🚀 支援開始"
        )

        print(
            "📝 支援内容:"
        )

        print(
            supportContent
        )

        print(
            "🎯 ステップ数: \(plan.count)"
        )

        // キャプチャ開始
        capture.startFullDisplayCapture()
    }

    // MARK: - OCR

    private func processOCR(
        _ text: String
    ) {

        guard isRunning else {
            return
        }

        guard currentStepIndex < plan.count else {
            return
        }

        lastOCR =
            text

        let step =
            plan[currentStepIndex]

        // ---------------------------------------------
        // 通知直後
        // ---------------------------------------------

        if Date() < notificationIgnoreUntil {

            print(
                "⏸️ 通知直後なので画面判定を待機"
            )

            return
        }

        // ---------------------------------------------
        // 手動終了ステップ
        // ---------------------------------------------

        if step.manualFinish {

            print(
                "🛑 手動操作ステップのため自動判定しません"
            )

            captureStatus =
                "ユーザーの操作を待っています"

            return
        }

        let normalizedOCR =
            normalize(text)

        guard !normalizedOCR.isEmpty else {

            print(
                "⚠️ OCR結果が空"
            )

            captureStatus =
                "画面を確認しています"

            return
        }

        print("================================")
        print(
            "🔍 現在ステップ: \(currentStepIndex)"
        )
        print(
            "📺 OCR:"
        )
        print(text)
        print(
            "🎯 判定候補:"
        )
        print(step.detectKeywords)
        print("================================")

        // ---------------------------------------------
        // 画面一致数
        // ---------------------------------------------

        let matchCount =
            countMatches(
                ocr: normalizedOCR,
                keywords: step.detectKeywords
            )

        print(
            "🔎 一致数: \(matchCount)/\(step.minimumMatches)"
        )

        // ---------------------------------------------
        // 画面が違う
        //
        // 現在の案内だけを通知する。
        // ただし連続通知はしない。
        // ---------------------------------------------

        if matchCount < step.minimumMatches {

            screenMatchCount =
                0

            captureStatus =
                "画面を確認しています"

            sendInstructionIfNeeded()

            return
        }

        // ---------------------------------------------
        // 画面が合っている
        // ---------------------------------------------

        screenMatchCount += 1

        captureStatus =
            "画面を確認中 \(screenMatchCount)/\(requiredStableMatches)"

        print(
            "✅ 画面条件一致 \(screenMatchCount)/\(requiredStableMatches)"
        )

        guard screenMatchCount >= requiredStableMatches else {
            return
        }

        // ---------------------------------------------
        // 次のステップへ
        // ---------------------------------------------

        screenMatchCount =
            0

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

                print(
                    "✅ 一致: \(keyword)"
                )
            }
        }

        return count
    }

    // MARK: - Send If Needed

    private func sendInstructionIfNeeded() {

        guard isRunning else {
            return
        }

        guard currentStepIndex < plan.count else {
            return
        }

        let now =
            Date()

        // 同じ案内を連続送信しない
        guard now.timeIntervalSince(
            lastNotificationDate
        ) >= notificationCooldown else {

            return
        }

        lastNotificationDate =
            now

        Task { @MainActor [weak self] in

            guard let self else {
                return
            }

            await self.sendCurrentInstruction()
        }
    }

    // MARK: - Advance

    private func advanceToNextStep() {

        currentStepIndex += 1

        // 全ステップ終了
        guard currentStepIndex < plan.count else {

            finishSupport()

            return
        }

        screenMatchCount =
            0

        let nextStep =
            plan[currentStepIndex]

        currentInstruction =
            nextStep.message

        print(
            "➡️ 次のステップ:"
        )

        print(
            nextStep.message
        )

        // ★前の画面を確認した後で次の通知を送る
        Task { @MainActor [weak self] in

            guard let self else {
                return
            }

            await self.sendCurrentInstruction()
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

        // 通知をOCRが読まないようにする
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
            "📣 通知:"
        )

        print(
            step.message
        )

        // ---------------------------------------------
        // 最後のステップ
        // ---------------------------------------------

        if step.manualFinish {

            isRunning =
                false

            captureStatus =
                "送信ボタンを押してください"

            print(
                "🛑 最終案内。ここで自動支援を終了"
            )
        }
    }

    // MARK: - Finish

    private func finishSupport() {

        isRunning =
            false

        capture.stop()

        currentInstruction =
            "支援が完了しました"

        captureStatus =
            "支援完了"

        notificationStatus =
            "支援完了"

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

                VStack(spacing: 20) {

                    // -----------------------------------------
                    // Title
                    // -----------------------------------------

                    VStack(spacing: 8) {

                        Text("よりそいAI")
                            .font(.largeTitle)
                            .fontWeight(.bold)

                        Text(
                            "やりたいことを入力してください"
                        )
                        .font(.headline)
                        .foregroundStyle(
                            .secondary
                        )
                    }

                    // -----------------------------------------
                    // 支援内容
                    // -----------------------------------------

                    VStack(
                        alignment: .leading,
                        spacing: 10
                    ) {

                        Text("支援内容")
                            .font(.headline)

                        Text(
                            "例：Teamsで田中さんにメッセージを送りたい"
                        )
                        .font(.subheadline)
                        .foregroundStyle(
                            .secondary
                        )

                        TextField(
                            "やりたいことを入力",
                            text: $model.supportContent,
                            axis: .vertical
                        )
                        .lineLimit(
                            3...5
                        )
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
                    // Status
                    // -----------------------------------------

                    VStack(
                        alignment: .leading,
                        spacing: 12
                    ) {

                        Text("状態")
                            .font(.headline)

                        HStack {

                            Text("支援")

                            Spacer()

                            Text(
                                model.isRunning
                                ? "実行中"
                                : "停止"
                            )
                        }

                        HStack {

                            Text("画面")

                            Spacer()

                            Text(
                                model.captureStatus
                            )
                        }

                        HStack {

                            Text("通知")

                            Spacer()

                            Text(
                                model.notificationStatus
                            )
                        }

                        Divider()

                        Text("現在の案内")
                            .font(.headline)

                        Text(
                            model.currentInstruction.isEmpty
                            ? "画面を確認しています"
                            : model.currentInstruction
                        )

                        Divider()

                        Text("画面認識")
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
                            minHeight: 100,
                            maxHeight: 220
                        )
                    }
                    .padding()
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                    .background(
                        RoundedRectangle(
                            cornerRadius: 12
                        )
                        .fill(
                            Color.secondary
                                .opacity(0.08)
                        )
                    )
                    .padding(.horizontal)

                    Spacer()
                }
                .padding(.top)
                .padding(.bottom, 30)
            }
            .navigationTitle(
                "よりそいAI"
            )
        }
    }
}
