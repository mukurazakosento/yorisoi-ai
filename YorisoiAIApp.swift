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

    // -----------------------------------------
    // 支援内容
    // -----------------------------------------

    @Published var supportContent: String = ""

    // -----------------------------------------
    // 表示状態
    // -----------------------------------------

    @Published var isRunning: Bool = false

    @Published var captureStatus: String =
        "待機中"

    @Published var lastOCR: String = ""

    @Published var notificationStatus: String =
        "通知確認中"

    @Published var currentInstruction: String =
        ""

    // -----------------------------------------
    // Services
    // -----------------------------------------

    private let capture =
        ScreenCaptureCoordinator()

    private let notifications =
        NotificationCoordinator()

    private let planner =
        InstructionPlanner()

    // -----------------------------------------
    // Plan
    // -----------------------------------------

    private var plan:
        [InstructionStep] = []

    private var currentStepIndex:
        Int = 0

    // -----------------------------------------
    // 画面安定判定
    // -----------------------------------------

    private var stableMatchCount:
        Int = 0

    private let requiredStableMatches:
        Int = 3

    // -----------------------------------------
    // 通知後の状態
    // -----------------------------------------

    private var waitingForUserAction:
        Bool = false

    private var screenBeforeInstruction:
        String = ""

    private var notificationIgnoreUntil:
        Date = .distantPast

    private let notificationIgnoreInterval:
        TimeInterval = 6

    // 現在のステップで通知済みか
    private var instructionSent:
        Bool = false

    // -----------------------------------------
    // 最初の画面を取得済みか
    // -----------------------------------------

    private var firstScreenReceived:
        Bool = false

    // -----------------------------------------
    // Init
    // -----------------------------------------

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

                self.firstScreenReceived =
                    false

                print(
                    "🔍 キャプチャ開始"
                )

                print(
                    "🔍 最初の画面を待っています"
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

        waitingForUserAction =
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

        guard currentStepIndex < plan.count
        else {
            return
        }

        lastOCR =
            text

        let normalizedOCR =
            normalize(text)

        // -----------------------------------------
        // 最初の画面を受信
        // -----------------------------------------

        if !firstScreenReceived {

            firstScreenReceived =
                true

            print(
                "📺 最初の画面を確認しました"
            )

            print(
                "📺 OCR: \(text)"
            )

            captureStatus =
                "画面を確認しています"
        }

        // -----------------------------------------
        // 通知直後
        // -----------------------------------------

        if Date() < notificationIgnoreUntil {

            print(
                "⏸️ 通知直後なので判定しません"
            )

            return
        }

        let step =
            plan[currentStepIndex]

        // -----------------------------------------
        // 最終ステップ
        // -----------------------------------------

        if step.manualFinish {

            print(
                "🛑 最終ステップ"
            )

            captureStatus =
                "文章を入力して送信してください"

            return
        }

        // -----------------------------------------
        // 通知を出した後
        // -----------------------------------------

        if waitingForUserAction {

            let changed =
                screenHasChanged(
                    old: screenBeforeInstruction,
                    new: normalizedOCR
                )

            // 画面が変わっていない
            if !changed {

                captureStatus =
                    "操作を待っています"

                print(
                    "⏸️ 画面がまだ変わっていません"
                )

                return
            }

            // -----------------------------------------
            // ユーザーが操作した
            // -----------------------------------------

            waitingForUserAction =
                false

            stableMatchCount =
                0

            instructionSent =
                false

            print(
                "🆕 画面が変わりました"
            )
        }

        // -----------------------------------------
        // OCRが空
        // -----------------------------------------

        if normalizedOCR.isEmpty {

            print(
                "⚠️ OCR結果が空です"
            )

            // 最初の画面なら
            // Teamsを開く通知を出す
            if currentStepIndex == 0 &&
                !instructionSent {

                sendCurrentInstruction()
            }

            return
        }

        // -----------------------------------------
        // 現在の画面を確認
        // -----------------------------------------

        let matched =
            matchesCurrentStep(
                step: step,
                ocr: normalizedOCR
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

        print(
            text
        )

        print(
            "🎯 条件:"
        )

        print(
            step.detectKeywords
        )

        print(
            "✅ 合致: \(matched)"
        )

        print(
            "================================"
        )

        // -----------------------------------------
        // 正しい画面
        // -----------------------------------------

        if matched {

            stableMatchCount += 1

            captureStatus =
                "正しい画面を確認中 \(stableMatchCount)/\(requiredStableMatches)"

            print(
                "✅ 正しい画面 \(stableMatchCount)/\(requiredStableMatches)"
            )

            if stableMatchCount >=
                requiredStableMatches {

                stableMatchCount =
                    0

                advanceToNextStep()
            }

            return
        }

        // -----------------------------------------
        // 正しい画面ではない
        //
        // ここで初めて現在の案内を通知
        // -----------------------------------------

        stableMatchCount =
            0

        captureStatus =
            "画面を確認しています"

        if !instructionSent {

            sendCurrentInstruction()
        } else {

            print(
                "⏸️ このステップの案内は送信済み"
            )
        }
    }

    // MARK: - Current Step Match

    private func matchesCurrentStep(
        step: InstructionStep,
        ocr: String
    ) -> Bool {

        var count =
            0

        for keyword in
            step.detectKeywords {

            let normalizedKeyword =
                normalize(keyword)

            guard !normalizedKeyword.isEmpty
            else {
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

        return count >=
            step.minimumMatches
    }

    // MARK: - Send Instruction

    private func sendCurrentInstruction() {

        guard isRunning else {
            return
        }

        guard currentStepIndex < plan.count
        else {
            return
        }

        guard !instructionSent else {

            print(
                "⏸️ 通知済み"
            )

            return
        }

        let step =
            plan[currentStepIndex]

        currentInstruction =
            step.message

        // -----------------------------------------
        // 現在の画面を保存
        // -----------------------------------------

        screenBeforeInstruction =
            normalize(lastOCR)

        // -----------------------------------------
        // これからユーザー操作を待つ
        // -----------------------------------------

        waitingForUserAction =
            true

        instructionSent =
            true

        stableMatchCount =
            0

        notificationIgnoreUntil =
            Date().addingTimeInterval(
                notificationIgnoreInterval
            )

        notificationStatus =
            "案内を送信中"

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

            print(
                "📣 通知:"
            )

            print(
                step.message
            )

            print(
                "⏸️ ユーザー操作待ち"
            )
        }
    }

    // MARK: - Advance

    private func advanceToNextStep() {

        currentStepIndex += 1

        // -----------------------------------------
        // 全ステップ完了
        // -----------------------------------------

        guard currentStepIndex < plan.count
        else {

            finishSupport()

            return
        }

        stableMatchCount =
            0

        instructionSent =
            false

        waitingForUserAction =
            false

        screenBeforeInstruction =
            ""

        notificationIgnoreUntil =
            .distantPast

        let nextStep =
            plan[currentStepIndex]

        currentInstruction =
            nextStep.message

        print(
            "➡️ 次のステップへ"
        )

        print(
            nextStep.message
        )

        // ★重要
        // ここではまだ通知しない。
        //
        // 次の画面をまず確認する。
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

    // MARK: - Screen Changed

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

        // 90%未満なら画面が変わったと判断
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

                    // ----------------------------------
                    // 支援内容
                    // ----------------------------------

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

                    // ----------------------------------
                    // 支援開始
                    // ----------------------------------

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

                    // ----------------------------------
                    // 状態
                    // ----------------------------------

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
