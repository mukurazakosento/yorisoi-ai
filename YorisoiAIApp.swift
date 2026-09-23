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

    // MARK: - 画面表示用

    @Published var supportContent: String = ""

    @Published var isRunning: Bool = false

    @Published var captureStatus: String = "待機中"

    @Published var lastOCR: String = ""

    @Published var notificationStatus: String = "通知確認中"

    @Published var currentInstruction: String = ""


    // MARK: - 各機能

    private let capture =
        ScreenCaptureCoordinator()

    private let notifications =
        NotificationCoordinator()

    private let planner =
        InstructionPlanner()


    // MARK: - 支援計画

    private var plan: [InstructionStep] = []

    private var currentStepIndex: Int = 0


    // MARK: - 画面判定

    private var stableMatchCount: Int = 0

    private let requiredStableMatches: Int = 3


    // MARK: - 通知後の状態

    private var waitingForScreenChange: Bool = false

    private var screenBeforeInstruction: String = ""

    private var notificationIgnoreUntil: Date = .distantPast

    private let notificationIgnoreInterval: TimeInterval = 4.0

    private var instructionSent: Bool = false


    // MARK: - 初回画面

    private var firstScreenReceived: Bool = false


    // MARK: - 初期化

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


    // MARK: - 通知確認

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


    // MARK: - 支援開始

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

        // -----------------------------
        // 支援計画を作成
        // -----------------------------

        plan =
            planner.makePlan(
                for: supportContent
            )


        guard !plan.isEmpty else {

            notificationStatus =
                "支援内容を作成できませんでした"

            return
        }


        // -----------------------------
        // 状態をリセット
        // -----------------------------

        currentStepIndex =
            0

        stableMatchCount =
            0

        waitingForScreenChange =
            false

        screenBeforeInstruction =
            ""

        notificationIgnoreUntil =
            .distantPast

        instructionSent =
            false

        firstScreenReceived =
            false

        currentInstruction =
            ""

        lastOCR =
            ""


        // -----------------------------
        // 通知許可
        // -----------------------------

        let granted =
            await notifications.requestPermission()


        guard granted else {

            notificationStatus =
                "通知OFF"

            return
        }


        notificationStatus =
            "通知ON"


        // -----------------------------
        // 実行開始
        // -----------------------------

        isRunning =
            true

        captureStatus =
            "画面を確認しています"


        print("================================")
        print("🚀 支援開始")
        print("📝 支援内容: \(supportContent)")
        print("📝 STEP数: \(plan.count)")
        print("================================")


        capture.startFullDisplayCapture()
    }


    // MARK: - OCR処理

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


        // -----------------------------
        // 初回画面
        // -----------------------------

        if !firstScreenReceived {

            firstScreenReceived =
                true

            print("================================")
            print("📺 最初の画面を確認")
            print("📺 OCR:")
            print(text)
            print("================================")

            captureStatus =
                "画面を確認しています"
        }


        // -----------------------------
        // OCRが空
        // -----------------------------

        guard !normalizedOCR.isEmpty else {

            print("⚠️ OCR結果が空です")

            return
        }


        // -----------------------------
        // 通知直後は判定しない
        // -----------------------------

        if Date() < notificationIgnoreUntil {

            print("⏸️ 通知直後なので判定しません")

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
        print("📝 manualFinish:")
        print(step.manualFinish)
        print("================================")


        // =========================================================
        // 最終ステップ
        // =========================================================

        if step.manualFinish {

            captureStatus =
                "文章を入力して送信してください"


            if !instructionSent {

                print("📣 最終ステップの案内を送信します")

                sendCurrentInstruction()
            }


            // ★ここでは自動完了しない
            // ユーザーがTeamsで「送信」を押す
            return
        }


        // =========================================================
        // 通知後、画面が変わるのを待つ
        // =========================================================

        if waitingForScreenChange {

            let changed =
                screenHasChanged(
                    old: screenBeforeInstruction,
                    new: normalizedOCR
                )


            if !changed {

                captureStatus =
                    "操作を待っています"

                print("⏸️ 画面がまだ変わっていません")

                return
            }


            // -----------------------------
            // 新しい画面を検出
            // -----------------------------

            waitingForScreenChange =
                false

            stableMatchCount =
                0

            print("================================")
            print("🆕 画面が変わりました")
            print("🆕 新しいOCR:")
            print(text)
            print("================================")
        }


        // =========================================================
        // 現在の画面が正しいか確認
        // =========================================================

        let matched =
            matchesCurrentStep(
                step: step,
                ocr: normalizedOCR
            )


        print("✅ 現在のSTEPと合致: \(matched)")


        if matched {

            // -----------------------------
            // 正しい画面
            // -----------------------------

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


        // =========================================================
        // 正しい画面ではない
        // =========================================================

        stableMatchCount =
            0


        captureStatus =
            "画面を確認しています"


        // -----------------------------
        // まだ案内していない
        // -----------------------------

        if !instructionSent {

            sendCurrentInstruction()

            return
        }


        // -----------------------------
        // 案内済みだが違う画面
        //
        // 再通知はしない
        // 次の画面変更を待つ
        // -----------------------------

        print("⏸️ このSTEPの案内は送信済み")
        print("⏸️ 現在の画面は条件に一致しません")
        print("⏸️ 再通知せず、次の画面変更を待ちます")


        screenBeforeInstruction =
            normalizedOCR

        waitingForScreenChange =
            true
    }


    // MARK: - STEP判定

    private func matchesCurrentStep(
        step: InstructionStep,
        ocr: String
    ) -> Bool {

        guard !step.keywordGroups.isEmpty else {
            return false
        }


        // keywordGroups:
        //
        // [
        //   ["Teams"],
        //   ["チャット", "アクティビティ", "チーム"]
        // ]
        //
        // ↑
        // 1つ目のグループは「Teams」が必要
        //
        // 2つ目は
        // 「チャット」または「アクティビティ」または「チーム」
        // のどれか1つがあればOK
        //
        // グループ同士はAND
        // グループ内はOR


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


            // 1つでもグループを満たせなければ
            // 現在の画面は不一致

            if !groupMatched {

                print(
                    "❌ キーワードグループ不一致: \(group)"
                )

                return false
            }
        }


        return true
    }


    // MARK: - 現在の案内を通知

    private func sendCurrentInstruction() {

        guard isRunning else {
            return
        }


        guard currentStepIndex < plan.count else {
            return
        }


        guard !instructionSent else {

            print("⏸️ すでに通知済み")

            return
        }


        let step =
            plan[currentStepIndex]


        currentInstruction =
            step.message


        // -----------------------------
        // 通知前の画面を保存
        // -----------------------------

        screenBeforeInstruction =
            normalize(lastOCR)


        // -----------------------------
        // 通知済み状態
        // -----------------------------

        instructionSent =
            true

        waitingForScreenChange =
            true

        stableMatchCount =
            0


        // -----------------------------
        // 通知直後のOCR誤判定防止
        // -----------------------------

        notificationIgnoreUntil =
            Date().addingTimeInterval(
                notificationIgnoreInterval
            )


        notificationStatus =
            "案内を送信中"


        print("================================")
        print("📣 通知送信")
        print("📣 STEP: \(currentStepIndex)")
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
            print("⏸️ ユーザー操作待ち")
        }
    }


    // MARK: - 次のSTEPへ

    private func advanceToNextStep() {

        currentStepIndex += 1


        // -----------------------------
        // 全STEP完了
        // -----------------------------

        guard currentStepIndex < plan.count else {

            finishSupport()

            return
        }


        let nextStep =
            plan[currentStepIndex]


        currentInstruction =
            nextStep.message


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


        print("================================")
        print("➡️ 次のSTEPへ")
        print("➡️ STEP: \(currentStepIndex)")
        print("➡️ \(nextStep.message)")
        print("================================")


        // -----------------------------
        // 最終手順の場合
        // -----------------------------

        if nextStep.manualFinish {

            print("📣 最終手順へ移行")

            sendCurrentInstruction()

            captureStatus =
                "文章を入力して送信してください"

            return
        }


        // -----------------------------
        // 次のSTEP
        //
        // 現在の画面が次のSTEPに合わなければ
        // ここで案内する
        //
        // これにより
        //
        // Teams画面確認
        // ↓
        // 「田中さんのチャットを開いてください」
        //
        // のような流れになる
        // -----------------------------

        captureStatus =
            "次の画面を確認しています"


        if !matchesCurrentStep(
            step: nextStep,
            ocr: normalize(lastOCR)
        ) {

            sendCurrentInstruction()
        }
    }


    // MARK: - 支援完了

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


    // MARK: - 画面変更判定

    private func screenHasChanged(
        old: String,
        new: String
    ) -> Bool {

        guard !old.isEmpty,
              !new.isEmpty
        else {

            return false
        }


        // 完全一致なら変化なし

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


        // 90%以上似ていれば
        // 同じ画面とみなす

        return similarity < 0.90
    }


    // MARK: - Bigram生成

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


    // MARK: - 正規化

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

                    // -----------------------------
                    // タイトル
                    // -----------------------------

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


                    // -----------------------------
                    // 支援内容
                    // -----------------------------

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


                    // -----------------------------
                    // 開始ボタン
                    // -----------------------------

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


                    // -----------------------------
                    // 状態
                    // -----------------------------

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
