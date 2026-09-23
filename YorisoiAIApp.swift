import SwiftUI

@main
struct YorisoiAIApp: App {

    @StateObject private var model =
        SupportModel()

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

    // 支援内容は1個だけ
    @Published var supportContent: String = ""

    @Published var isRunning: Bool = false

    @Published var captureStatus: String = "待機中"

    @Published var lastOCR: String = ""

    @Published var notificationStatus: String = "通知確認中"

    @Published var currentInstruction: String = ""

    private let capture =
        ScreenCaptureCoordinator()

    private let notifications =
        NotificationCoordinator()

    private let planner =
        InstructionPlanner()

    private var plan:
        [InstructionStep] = []

    private var currentStepIndex:
        Int = 0

    // 同じ画面を連続確認した回数
    private var stableMatchCount:
        Int = 0

    // 3回同じ画面を確認
    private let requiredStableMatches:
        Int = 3

    // --------------------------------------------------
    // ★通知を出した後の状態
    // --------------------------------------------------

    // 通知後、まだ新しい画面を確認していない
    private var waitingForScreenChange:
        Bool = false

    // 通知を出す直前の画面
    private var screenBeforeNotification:
        String = ""

    // 通知直後は数秒判定しない
    private var notificationIgnoreUntil:
        Date = .distantPast

    private let notificationIgnoreInterval:
        TimeInterval = 6

    // 同じ案内を2回連続で送らない
    private var notificationSentForCurrentStep:
        Bool = false

    // MARK: - Init

    init() {

        capture.onOCR = {
            [weak self] text in

            Task { @MainActor [weak self] in

                guard let self else {
                    return
                }

                self.processOCR(text)
            }
        }

        capture.onStatus = {
            [weak self] status in

            Task { @MainActor [weak self] in

                self?.captureStatus =
                    status
            }
        }

        capture.onCaptureStarted = {
            [weak self] in

            Task { @MainActor [weak self] in

                guard let self else {
                    return
                }

                self.captureStatus =
                    "画面を確認しています"

                print(
                    "🔍 キャプチャ開始"
                )

                print(
                    "🔍 まず実際の画面を確認します"
                )

                // ★ここでは通知しない
            }
        }

        Task { @MainActor [weak self] in

            guard let self else {
                return
            }

            await self.checkNotificationStatus()
        }
    }

    // MARK: - Notification Status

    private func checkNotificationStatus()
        async {

        let granted =
            await notifications
                .requestPermission()

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

        plan =
            planner.makePlan(
                for: supportContent
            )

        guard !plan.isEmpty else {

            notificationStatus =
                "支援内容を作成できませんでした"

            return
        }

        currentStepIndex =
            0

        stableMatchCount =
            0

        waitingForScreenChange =
            false

        screenBeforeNotification =
            ""

        notificationIgnoreUntil =
            .distantPast

        notificationSentForCurrentStep =
            false

        currentInstruction =
            ""

        let granted =
            await notifications
                .requestPermission()

        guard granted else {

            notificationStatus =
                "通知OFF"

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
            "📝 支援内容: \(supportContent)"
        )

        capture.startFullDisplayCapture()
    }

    // MARK: - OCR

    private func processOCR(
        _ text: String
    ) {

        guard isRunning else {
            return
        }

        guard currentStepIndex < plan.count
        else {
            return
        }

        lastOCR =
            text

        let normalizedOCR =
            normalize(text)

        guard !normalizedOCR.isEmpty else {
            return
        }

        // --------------------------------------------------
        // 通知直後
        // --------------------------------------------------

        if Date() < notificationIgnoreUntil {

            print(
                "⏸️ 通知直後なので判定しません"
            )

            return
        }

        // --------------------------------------------------
        // ★通知を出したあと
        //
        // 実際に画面が変わるまで何もしない
        // --------------------------------------------------

        if waitingForScreenChange {

            let changed =
                isMeaningfullyDifferent(
                    old: screenBeforeNotification,
                    new: normalizedOCR
                )

            if !changed {

                print(
                    "⏸️ 画面が変わっていません"
                )

                captureStatus =
                    "操作を待っています"

                return
            }

            // 新しい画面を確認
            waitingForScreenChange =
                false

            stableMatchCount =
                0

            print(
                "🆕 新しい画面を確認しました"
            )
        }

        let step =
            plan[currentStepIndex]

        // --------------------------------------------------
        // 最終ステップ
        // --------------------------------------------------

        if step.manualFinish {

            print(
                "🛑 最終ステップ"
            )

            return
        }

        // --------------------------------------------------
        // 現在の画面が目的の画面か確認
        // --------------------------------------------------

        let screenMatches =
            matchesScreen(
                ocr: normalizedOCR,
                groups: step.keywordGroups
            )

        print(
            "================================"
        )

        print(
            "🔍 STEP \(currentStepIndex)"
        )

        print(
            "📺 OCR:"
        )

        print(text)

        print(
            "🎯 画面条件:"
        )

        print(
            step.keywordGroups
        )

        print(
            "✅ 画面一致: \(screenMatches)"
        )

        print(
            "================================"
        )

        // --------------------------------------------------
        // 目的の画面ではない
        //
        // ★通知しない
        // ★次へ進まない
        // --------------------------------------------------

        guard screenMatches else {

            stableMatchCount =
                0

            captureStatus =
                "画面を確認しています"

            print(
                "❌ 目的の画面ではありません"
            )

            return
        }

        // --------------------------------------------------
        // 目的の画面を確認
        // --------------------------------------------------

        stableMatchCount += 1

        captureStatus =
            "画面確認中 \(stableMatchCount)/\(requiredStableMatches)"

        print(
            "✅ 正しい画面 \(stableMatchCount)/\(requiredStableMatches)"
        )

        // 3回連続で確認
        guard stableMatchCount
                >= requiredStableMatches
        else {
            return
        }

        stableMatchCount =
            0

        // --------------------------------------------------
        // 現在の画面を確認できた
        //
        // ここで初めて次の通知
        // --------------------------------------------------

        advanceToNextStep()
    }

    // MARK: - Screen Matching

    private func matchesScreen(
        ocr: String,
        groups: [[String]]
    ) -> Bool {

        guard !groups.isEmpty else {
            return false
        }

        // すべてのグループを満たす必要がある
        for group in groups {

            var groupMatched =
                false

            for keyword in group {

                let normalizedKeyword =
                    normalize(keyword)

                guard !normalizedKeyword.isEmpty
                else {
                    continue
                }

                if ocr.contains(
                    normalizedKeyword
                ) {

                    groupMatched =
                        true

                    print(
                        "✅ 一致文字: \(keyword)"
                    )

                    break
                }
            }

            // 1グループでも満たさなければNG
            if !groupMatched {

                return false
            }
        }

        return true
    }

    // MARK: - Advance

    private func advanceToNextStep() {

        currentStepIndex += 1

        // --------------------------------------------------
        // 全ステップ終了
        // --------------------------------------------------

        guard currentStepIndex < plan.count
        else {

            finishSupport()

            return
        }

        let nextStep =
            plan[currentStepIndex]

        currentInstruction =
            nextStep.message

        notificationSentForCurrentStep =
            false

        waitingForScreenChange =
            false

        screenBeforeNotification =
            ""

        notificationIgnoreUntil =
            .distantPast

        print(
            "➡️ 画面確認成功"
        )

        print(
            "➡️ 次のステップへ"
        )

        print(
            nextStep.message
        )

        // 次の通知を送る
        Task { @MainActor [weak self] in

            guard let self else {
                return
            }

            await self.sendCurrentInstruction()
        }
    }

    // MARK: - Send Instruction

    private func sendCurrentInstruction()
        async {

        guard currentStepIndex < plan.count
        else {
            return
        }

        // 同じステップの通知は1回だけ
        guard !notificationSentForCurrentStep
        else {

            print(
                "⏸️ このステップの通知はすでに送信済み"
            )

            return
        }

        let step =
            plan[currentStepIndex]

        currentInstruction =
            step.message

        // この時点の画面を保存
        screenBeforeNotification =
            normalize(lastOCR)

        // ★通知を送ったら、
        // 実際に画面が変わるまで判定停止
        waitingForScreenChange =
            true

        notificationIgnoreUntil =
            Date().addingTimeInterval(
                notificationIgnoreInterval
            )

        notificationSentForCurrentStep =
            true

        notificationStatus =
            "案内を送信中"

        await notifications.send(
            title: "よりそいAI",
            body: step.message
        )

        notificationStatus =
            "通知送信済み"

        print(
            "📣 通知送信:"
        )

        print(
            step.message
        )

        // --------------------------------------------------
        // 最終案内
        // --------------------------------------------------

        if step.manualFinish {

            isRunning =
                false

            captureStatus =
                "メッセージを入力して送信してください"

            print(
                "🛑 最終案内で支援終了"
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

    // MARK: - Screen Change Detection

    private func isMeaningfullyDifferent(
        old: String,
        new: String
    ) -> Bool {

        guard !old.isEmpty,
              !new.isEmpty
        else {
            return false
        }

        if old == new {
            return false
        }

        let oldGrams =
            makeBigrams(old)

        let newGrams =
            makeBigrams(new)

        if oldGrams.isEmpty ||
            newGrams.isEmpty {

            return old != new
        }

        let intersection =
            oldGrams.intersection(
                newGrams
            ).count

        let union =
            oldGrams.union(
                newGrams
            ).count

        guard union > 0 else {
            return false
        }

        let similarity =
            Double(intersection)
            / Double(union)

        print(
            "📊 画面変化率: \(1.0 - similarity)"
        )

        // 類似度が90%未満なら
        // 「画面が変わった」と判断
        return similarity < 0.90
    }

    private func makeBigrams(
        _ text: String
    ) -> Set<String> {

        let characters =
            Array(text)

        guard characters.count >= 2
        else {
            return []
        }

        var result =
            Set<String>()

        for index in 0..<(characters.count - 1) {

            let gram =
                String(
                    characters[index]
                )
                +
                String(
                    characters[index + 1]
                )

            result.insert(
                gram
            )
        }

        return result
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

                VStack(
                    spacing: 20
                ) {

                    // -------------------------------------
                    // タイトル
                    // -------------------------------------

                    VStack(
                        spacing: 8
                    ) {

                        Text(
                            "よりそいAI"
                        )
                        .font(
                            .largeTitle
                        )
                        .fontWeight(
                            .bold
                        )

                        Text(
                            "やりたいことを入力してください"
                        )
                        .font(
                            .headline
                        )
                        .foregroundStyle(
                            .secondary
                        )
                    }

                    // -------------------------------------
                    // 支援内容
                    // -------------------------------------

                    VStack(
                        alignment: .leading,
                        spacing: 10
                    ) {

                        Text(
                            "支援内容"
                        )
                        .font(
                            .headline
                        )

                        Text(
                            "例：Teamsで田中さんにメッセージを送りたい"
                        )
                        .font(
                            .subheadline
                        )
                        .foregroundStyle(
                            .secondary
                        )

                        TextField(
                            "やりたいことを入力",
                            text:
                                $model.supportContent,
                            axis: .vertical
                        )
                        .lineLimit(
                            3...5
                        )
                        .textFieldStyle(
                            .roundedBorder
                        )
                    }
                    .padding(
                        .horizontal
                    )

                    // -------------------------------------
                    // 開始ボタン
                    // -------------------------------------

                    Button {

                        model.start()

                    } label: {

                        Text(
                            model.isRunning
                            ? "支援中"
                            : "支援を開始"
                        )
                        .font(
                            .headline
                        )
                        .frame(
                            maxWidth:
                                .infinity
                        )
                        .padding()
                    }
                    .buttonStyle(
                        .borderedProminent
                    )
                    .padding(
                        .horizontal
                    )

                    // -------------------------------------
                    // 状態
                    // -------------------------------------

                    VStack(
                        alignment: .leading,
                        spacing: 12
                    ) {

                        Text(
                            "状態"
                        )
                        .font(
                            .headline
                        )

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

                        Text(
                            "現在の案内"
                        )
                        .font(
                            .headline
                        )

                        Text(
                            model.currentInstruction.isEmpty
                            ? "画面を確認しています"
                            : model.currentInstruction
                        )

                        Divider()

                        Text(
                            "画面認識"
                        )
                        .font(
                            .headline
                        )

                        ScrollView {

                            Text(
                                model.lastOCR.isEmpty
                                ? "まだ画面を認識していません"
                                : model.lastOCR
                            )
                            .frame(
                                maxWidth:
                                    .infinity,
                                alignment:
                                    .leading
                            )
                        }
                        .frame(
                            minHeight: 100,
                            maxHeight: 220
                        )
                    }
                    .padding()
                    .frame(
                        maxWidth:
                            .infinity,
                        alignment:
                            .leading
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
                    .padding(
                        .horizontal
                    )

                    Spacer()
                }
                .padding(
                    .top
                )
                .padding(
                    .bottom,
                    30
                )
            }
            .navigationTitle(
                "よりそいAI"
            )
        }
    }
}
