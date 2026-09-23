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
    // MARK: - UI
    // ============================================================

    @Published var supportContent: String = ""

    @Published var isRunning: Bool = false

    @Published var captureStatus: String = "待機中"

    @Published var lastOCR: String = ""

    @Published var notificationStatus: String = "通知確認中"

    @Published var currentInstruction: String = ""


    // ============================================================
    // MARK: - Services
    // ============================================================

    private let capture =
        ScreenCaptureCoordinator()

    private let notifications =
        NotificationCoordinator()

    private let planner =
        InstructionPlanner()


    // ============================================================
    // MARK: - Plan
    // ============================================================

    private var plan: [InstructionStep] = []

    private var currentStepIndex: Int = 0


    // ============================================================
    // MARK: - Stable screen recognition
    // ============================================================

    private var stableMatchCount: Int = 0

    private let requiredStableMatches: Int = 3


    // ============================================================
    // MARK: - Instruction state
    // ============================================================

    private var instructionSent: Bool = false

    private var waitingForScreenChange: Bool = false

    private var screenBeforeInstruction: String = ""


    // ============================================================
    // MARK: - Notification protection
    // ============================================================

    private var notificationIgnoreUntil: Date = .distantPast

    private let notificationIgnoreInterval: TimeInterval = 4.0


    // ============================================================
    // MARK: - Initial screen
    // ============================================================

    private var firstScreenReceived: Bool = false


    // ============================================================
    // MARK: - Init
    // ============================================================

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

                guard let self else {
                    return
                }

                self.captureStatus = status
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
                print("🔍 最初の画面を待っています")
                print("================================")

                // ここでは通知しない
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
    // MARK: - Notification permission
    // ============================================================

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


    // ============================================================
    // MARK: - Start
    // ============================================================

    func start() {

        guard !isRunning else {

            print("⏸️ すでに支援中です")

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

        // --------------------------------------------------------
        // 支援計画作成
        // --------------------------------------------------------

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


        // --------------------------------------------------------
        // 通知許可
        // --------------------------------------------------------

        let granted =
            await notifications.requestPermission()


        guard granted else {

            notificationStatus =
                "通知OFF"

            return
        }


        notificationStatus =
            "通知ON"


        // --------------------------------------------------------
        // 実行
        // --------------------------------------------------------

        isRunning =
            true

        captureStatus =
            "画面を確認しています"


        print("================================")
        print("🚀 支援開始")
        print("📝 \(supportContent)")
        print("📝 STEP数: \(plan.count)")
        print("================================")


        capture.startFullDisplayCapture()
    }


    // ============================================================
    // MARK: - OCR
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


        // --------------------------------------------------------
        // 初回画面
        // --------------------------------------------------------

        if !firstScreenReceived {

            firstScreenReceived =
                true

            print("================================")
            print("📺 最初の画面")
            print("📺 OCR:")
            print(text)
            print("================================")

            captureStatus =
                "画面を確認しています"
        }


        // --------------------------------------------------------
        // OCRなし
        // --------------------------------------------------------

        guard !normalizedOCR.isEmpty else {

            print("⚠️ OCR結果が空です")

            return
        }


        // --------------------------------------------------------
        // 通知直後
        // --------------------------------------------------------

        if Date() < notificationIgnoreUntil {

            print("⏸️ 通知直後のため判定を一時停止")

            return
        }


        let step =
            plan[currentStepIndex]


        print("================================")
        print("🔍 STEP \(currentStepIndex)")
        print("📺 OCR:")
        print(text)
        print("🎯 条件:")
        print(step.keywordGroups)
        print("📝 manualFinish: \(step.manualFinish)")
        print("📣 instructionSent: \(instructionSent)")
        print("⏸️ waitingForScreenChange: \(waitingForScreenChange)")
        print("================================")


        // ========================================================
        // 最終STEP
        // ========================================================

        if step.manualFinish {

            captureStatus =
                "文章を入力して送信してください"


            if !instructionSent {

                sendManualInstruction()
            }


            // ★送信ボタンはユーザーが押す
            return
        }


        // ========================================================
        // 通知後の最初の画面変更だけ確認
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

                print("⏸️ 通知前と同じ画面です")

                return
            }


            // ----------------------------------------------------
            // 画面が変わった
            //
            // ここからは「正しい画面になるまで」
            // OCR判定を続ける
            // ----------------------------------------------------

            waitingForScreenChange =
                false

            stableMatchCount =
                0

            captureStatus =
                "画面が変わりました。正しい画面を確認しています"

            print("================================")
            print("🆕 画面変更を確認")
            print("🆕 OCR:")
            print(text)
            print("================================")
        }


        // ========================================================
        // 現在の画面が正しいか
        // ========================================================

        let matched =
            matchesCurrentStep(
                step: step,
                ocr: normalizedOCR
            )


        print("✅ 現在の画面と一致: \(matched)")


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


        // ========================================================
        // 不一致
        // ========================================================

        stableMatchCount =
            0


        captureStatus =
            "画面を確認しています"


        // --------------------------------------------------------
        // このSTEPの通知をまだ送っていない
        // --------------------------------------------------------

        if !instructionSent {

            print("📣 このSTEPの通知を送ります")

            sendCurrentInstruction()

            return
        }


        // --------------------------------------------------------
        // すでに通知済み
        //
        // ★ここでは再通知しない
        // ★正しい画面になるまで監視し続ける
        // --------------------------------------------------------

        print("⏸️ このSTEPは通知済み")
        print("⏸️ 正しい画面になるまで監視します")
    }


    // ============================================================
    // MARK: - Screen matching
    // ============================================================

    private func matchesCurrentStep(
        step: InstructionStep,
        ocr: String
    ) -> Bool {

        guard !step.keywordGroups.isEmpty else {

            return false
        }


        // keywordGroups
        //
        // [
        //    ["Teams"],
        //    ["チャット", "アクティビティ", "チーム"]
        // ]
        //
        // グループ同士 → AND
        // グループ内 → OR


        for group in step.keywordGroups {

            guard !group.isEmpty else {
                continue
            }


            var groupMatched =
                false


            for keyword in group {

                let normalizedKeyword =
                    normalize(keyword)


                guard !normalizedKeyword.isEmpty else {
                    continue
                }


                if ocr.contains(
                    normalizedKeyword
                ) {

                    groupMatched =
                        true

                    print(
                        "✅ キーワード一致: \(keyword)"
                    )

                    break
                }
            }


            if !groupMatched {

                print(
                    "❌ グループ不一致: \(group)"
                )

                return false
            }
        }


        return true
    }


    // ============================================================
    // MARK: - Send normal instruction
    // ============================================================

    private func sendCurrentInstruction() {

        guard isRunning else {
            return
        }


        guard currentStepIndex < plan.count else {
            return
        }


        guard !instructionSent else {

            print("⏸️ このSTEPはすでに通知済み")

            return
        }


        let step =
            plan[currentStepIndex]


        guard !step.manualFinish else {

            sendManualInstruction()

            return
        }


        currentInstruction =
            step.message


        // --------------------------------------------------------
        // 通知前の画面保存
        // --------------------------------------------------------

        screenBeforeInstruction =
            normalize(lastOCR)


        // --------------------------------------------------------
        // 状態
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
        print("📣 通知送信")
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


            print("✅ 通知処理完了")
            print("⏸️ ユーザー操作待ち")
        }
    }


    // ============================================================
    // MARK: - Send manual instruction
    // ============================================================

    private func sendManualInstruction() {

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


        instructionSent =
            true


        waitingForScreenChange =
            false


        stableMatchCount =
            0


        notificationStatus =
            "案内を送信中"


        captureStatus =
            "文章を入力して送信してください"


        print("================================")
        print("📣 最終案内")
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


            print("✅ 最終案内送信完了")
            print("🛑 ここからはユーザー操作")
        }
    }


    // ============================================================
    // MARK: - Next step
    // ============================================================

    private func advanceToNextStep() {

        currentStepIndex += 1


        // --------------------------------------------------------
        // 全STEP完了
        // --------------------------------------------------------

        guard currentStepIndex < plan.count else {

            finishSupport()

            return
        }


        // --------------------------------------------------------
        // 次STEPを初期化
        // --------------------------------------------------------

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


        let nextStep =
            plan[currentStepIndex]


        currentInstruction =
            nextStep.message


        print("================================")
        print("➡️ 次のSTEPへ")
        print("➡️ STEP \(currentStepIndex)")
        print("➡️ \(nextStep.message)")
        print("================================")


        // ========================================================
        // 最終STEP
        // ========================================================

        if nextStep.manualFinish {

            sendManualInstruction()

            return
        }


        // ========================================================
        // 次の画面がすでに正しいか確認
        // ========================================================

        let currentOCR =
            normalize(lastOCR)


        let alreadyCorrect =
            matchesCurrentStep(
                step: nextStep,
                ocr: currentOCR
            )


        if alreadyCorrect {

            // ----------------------------------------------------
            // すでに次STEPの画面にいる
            // ----------------------------------------------------

            stableMatchCount =
                1


            captureStatus =
                "正しい画面を確認中 1/\(requiredStableMatches)"


            print("✅ 次STEPの画面にすでに到達しています")


            // 次のOCRで安定確認を続行
            return
        }


        // --------------------------------------------------------
        // まだ次STEPの画面ではない
        // --------------------------------------------------------

        sendCurrentInstruction()
    }


    // ============================================================
    // MARK: - Finish
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
    // MARK: - Screen change
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
    // MARK: - Bigrams
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
    // MARK: - Normalize
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
// MARK: - UI
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

                    // ------------------------------------------------
                    // タイトル
                    // ------------------------------------------------

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


                    // ------------------------------------------------
                    // 支援内容
                    // ------------------------------------------------

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


                    // ------------------------------------------------
                    // 開始ボタン
                    // ------------------------------------------------

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


                    // ------------------------------------------------
                    // 状態
                    // ------------------------------------------------

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
