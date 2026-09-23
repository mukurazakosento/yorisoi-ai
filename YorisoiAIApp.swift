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

@MainActor
final class SupportModel: ObservableObject {

    // ============================================================
    // UI
    // ============================================================

    @Published var supportContent: String = ""

    @Published var isRunning: Bool = false

    @Published var captureStatus: String = "待機中"

    @Published var lastOCR: String = ""

    @Published var notificationStatus: String = "通知確認中"

    @Published var currentInstruction: String = ""


    // ============================================================
    // Services
    // ============================================================

    private let capture =
        ScreenCaptureCoordinator()

    private let notifications =
        NotificationCoordinator()

    private let planner =
        InstructionPlanner()


    // ============================================================
    // Plan
    // ============================================================

    private var plan: [InstructionStep] = []

    private var currentStepIndex: Int = 0


    // ============================================================
    // Stable match
    // ============================================================

    private var stableMatchCount: Int = 0

    private let requiredStableMatches: Int = 3


    // ============================================================
    // Notification / screen state
    // ============================================================

    private var instructionSent: Bool = false

    private var waitingForScreenChange: Bool = false

    private var screenBeforeInstruction: String = ""

    private var notificationIgnoreUntil: Date = .distantPast

    private let notificationIgnoreInterval: TimeInterval = 4.0


    // ============================================================
    // First screen
    // ============================================================

    private var firstScreenReceived: Bool = false


    // ============================================================
    // Init
    // ============================================================

    init() {

        capture.onOCR = {
            [weak self] text in

            Task { @MainActor [weak self] in

                guard let self else {
                    return
                }

                self.processOCR(
                    text
                )
            }
        }


        capture.onStatus = {
            [weak self] status in

            Task { @MainActor [weak self] in

                guard let self else {
                    return
                }

                self.captureStatus =
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

                self.firstScreenReceived =
                    false

                print("================================")
                print("🔍 キャプチャ開始")
                print("🔍 最初の画面待ち")
                print("================================")
            }
        }


        Task { @MainActor [weak self] in

            guard let self else {
                return
            }

            await self.checkNotificationStatus()
        }
    }


    // ============================================================
    // Notification permission
    // ============================================================

    private func checkNotificationStatus() async {

        let granted =
            await notifications.requestPermission()


        notificationStatus =
            granted
            ? "通知ON"
            : "通知OFF"
    }


    // ============================================================
    // Start
    // ============================================================

    func start() {

        guard !isRunning else {
            return
        }


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


        // --------------------------------------------------------
        // 状態リセット
        // --------------------------------------------------------

        currentStepIndex =
            0

        stableMatchCount =
            0

        instructionSent =
            false

        waitingForScreenChange =
            false

        screenBeforeInstruction =
            ""

        notificationIgnoreUntil =
            .distantPast

        firstScreenReceived =
            false

        currentInstruction =
            ""

        lastOCR =
            ""


        let granted =
            await notifications.requestPermission()


        guard granted else {

            notificationStatus =
                "通知OFF"

            return
        }


        isRunning =
            true


        captureStatus =
            "画面を確認しています"

        notificationStatus =
            "通知ON"


        print("================================")
        print("🚀 支援開始")
        print("📝 \(supportContent)")
        print("================================")


        capture.startFullDisplayCapture()
    }


    // ============================================================
    // OCR processing
    // ============================================================

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


        let normalizedOCR =
            normalize(text)


        guard !normalizedOCR.isEmpty else {

            print("⚠️ OCR結果なし")

            return
        }


        // --------------------------------------------------------
        // First screen
        // --------------------------------------------------------

        if !firstScreenReceived {

            firstScreenReceived =
                true

            print("================================")
            print("📺 初回画面取得")
            print("📺 \(text)")
            print("================================")
        }


        // --------------------------------------------------------
        // Notification immediately after
        // --------------------------------------------------------

        if Date() < notificationIgnoreUntil {

            print("⏸️ 通知直後")

            return
        }


        let step =
            plan[currentStepIndex]


        // --------------------------------------------------------
        // Manual finish step
        // --------------------------------------------------------

        if step.manualFinish {

            captureStatus =
                "文章を入力して送信してください"


            if !instructionSent {

                sendCurrentInstruction()
            }


            return
        }


        // ========================================================
        // 通知後の画面変更待ち
        // ========================================================

        if waitingForScreenChange {

            let changed =
                screenHasChanged(
                    old: screenBeforeInstruction,
                    new: normalizedOCR
                )


            if !changed {

                captureStatus =
                    "操作を待っています"

                print("⏸️ 画面変化なし")

                return
            }


            // ★ここが重要
            //
            // 画面が変わっただけでは
            // STEP達成にしない。
            //
            // 新しい画面をそのまま判定する。

            waitingForScreenChange =
                false

            stableMatchCount =
                0

            captureStatus =
                "新しい画面を確認しています"

            print("================================")
            print("🆕 画面変更検出")
            print("🆕 OCR:")
            print(text)
            print("================================")
        }


        // ========================================================
        // 現在画面のSTEP判定
        // ========================================================

        let matched =
            matchesCurrentStep(
                step: step,
                ocr: normalizedOCR
            )


        print("================================")
        print("🔍 STEP \(currentStepIndex)")
        print("✅ matched = \(matched)")
        print("🎯 keywords = \(step.detectKeywords)")
        print("🎯 minimum = \(step.minimumMatches)")
        print("📺 OCR:")
        print(text)
        print("================================")


        if matched {

            stableMatchCount += 1


            captureStatus =
                "正しい画面を確認中 \(stableMatchCount)/\(requiredStableMatches)"


            print(
                "✅ 正しい画面 \(stableMatchCount)/\(requiredStableMatches)"
            )


            if stableMatchCount >= requiredStableMatches {

                stableMatchCount =
                    0

                advanceToNextStep()
            }


            return
        }


        // --------------------------------------------------------
        // 不一致
        // --------------------------------------------------------

        stableMatchCount =
            0


        captureStatus =
            "画面を確認しています"


        // --------------------------------------------------------
        // 初回案内
        // --------------------------------------------------------

        if !instructionSent {

            sendCurrentInstruction()

            return
        }


        // --------------------------------------------------------
        // すでに案内済み
        //
        // ★再通知しない
        // ★現在画面を維持して監視する
        // --------------------------------------------------------

        print("⏸️ 案内済み")
        print("⏸️ 正しい画面を待っています")
    }


    // ============================================================
    // STEP match
    // ============================================================

    private func matchesCurrentStep(
        step: InstructionStep,
        ocr: String
    ) -> Bool {

        guard !step.detectKeywords.isEmpty else {

            return false
        }


        var matchCount =
            0


        for keyword in
            step.detectKeywords {

            let normalizedKeyword =
                normalize(keyword)


            guard !normalizedKeyword.isEmpty else {
                continue
            }


            if ocr.contains(
                normalizedKeyword
            ) {

                matchCount += 1

                print(
                    "✅ キーワード一致: \(keyword)"
                )
            }
        }


        print(
            "📊 キーワード一致数: \(matchCount)"
        )


        return matchCount >=
            step.minimumMatches
    }


    // ============================================================
    // Send instruction
    // ============================================================

    private func sendCurrentInstruction() {

        guard isRunning else {
            return
        }


        guard currentStepIndex < plan.count else {
            return
        }


        guard !instructionSent else {
            return
        }


        let step =
            plan[currentStepIndex]


        currentInstruction =
            step.message


        // --------------------------------------------------------
        // 通知前の画面を保存
        // --------------------------------------------------------

        screenBeforeInstruction =
            normalize(lastOCR)


        // --------------------------------------------------------
        // 状態変更
        // --------------------------------------------------------

        instructionSent =
            true

        waitingForScreenChange =
            true

        stableMatchCount =
            0


        notificationIgnoreUntil =
            Date().addingTimeInterval(
                notificationIgnoreInterval
            )


        notificationStatus =
            "案内を送信中"


        captureStatus =
            "操作を待っています"


        print("================================")
        print("📣 通知")
        print("📣 STEP \(currentStepIndex)")
        print("📣 \(step.message)")
        print("================================")


        Task { @MainActor [weak self] in

            guard let self else {
                return
            }


            await self.notifications.send(
                title: "よりそいAI",
                body: step.message
            )


            self.notificationStatus =
                "通知送信済み"


            print("✅ 通知送信完了")
        }
    }


    // ============================================================
    // Next STEP
    // ============================================================

    private func advanceToNextStep() {

        currentStepIndex += 1


        guard currentStepIndex < plan.count else {

            finishSupport()

            return
        }


        let nextStep =
            plan[currentStepIndex]


        instructionSent =
            false

        waitingForScreenChange =
            false

        screenBeforeInstruction =
            ""

        notificationIgnoreUntil =
            .distantPast

        stableMatchCount =
            0

        currentInstruction =
            nextStep.message


        print("================================")
        print("➡️ NEXT STEP")
        print("➡️ STEP \(currentStepIndex)")
        print("➡️ \(nextStep.message)")
        print("================================")


        // --------------------------------------------------------
        // 最終STEP
        // --------------------------------------------------------

        if nextStep.manualFinish {

            sendCurrentInstruction()

            return
        }


        // --------------------------------------------------------
        // 現在画面がすでに次STEPなら
        // その画面を連続確認する
        // --------------------------------------------------------

        let currentOCR =
            normalize(lastOCR)


        if matchesCurrentStep(
            step: nextStep,
            ocr: currentOCR
        ) {

            stableMatchCount =
                1


            captureStatus =
                "正しい画面を確認中 1/\(requiredStableMatches)"


            return
        }


        // --------------------------------------------------------
        // 次STEPの画面ではない
        // → 次の案内を通知
        // --------------------------------------------------------

        sendCurrentInstruction()
    }


    // ============================================================
    // Finish
    // ============================================================

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


        print("================================")
        print("🎉 支援完了")
        print("================================")
    }


    // ============================================================
    // Screen changed
    // ============================================================

    private func screenHasChanged(
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


        let oldBigrams =
            makeBigrams(old)


        let newBigrams =
            makeBigrams(new)


        guard !oldBigrams.isEmpty,
              !newBigrams.isEmpty
        else {

            return old != new
        }


        let common =
            oldBigrams.intersection(
                newBigrams
            ).count


        let total =
            oldBigrams.union(
                newBigrams
            ).count


        guard total > 0 else {

            return false
        }


        let similarity =
            Double(common)
            / Double(total)


        print(
            "📊 画面類似度: \(similarity)"
        )


        return similarity < 0.90
    }


    // ============================================================
    // Bigrams
    // ============================================================

    private func makeBigrams(
        _ text: String
    ) -> Set<String> {

        let characters =
            Array(text)


        guard characters.count >= 2 else {

            return []
        }


        var result =
            Set<String>()


        for index in
            0..<(characters.count - 1) {

            let bigram =
                String(
                    characters[index]
                )
                +
                String(
                    characters[index + 1]
                )


            result.insert(
                bigram
            )
        }


        return result
    }


    // ============================================================
    // Normalize
    // ============================================================

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


// ============================================================
// UI
// ============================================================

struct ContentView: View {

    @EnvironmentObject var model:
        SupportModel


    var body: some View {

        NavigationStack {

            ScrollView {

                VStack(
                    spacing: 20
                ) {

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
                    .disabled(
                        model.isRunning
                    )
                    .padding(
                        .horizontal
                    )


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
