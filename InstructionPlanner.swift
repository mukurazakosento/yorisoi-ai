import Foundation

struct InstructionStep: Identifiable {
    let id = UUID()

    let message: String

    // OCRで画面を判定するための候補文字
    let detectKeywords: [String]

    // 候補のうち何個一致したら画面OKとするか
    let minimumMatches: Int

    // trueなら、このステップは通知したところで自動判定終了
    let manualFinish: Bool
}

@MainActor
final class InstructionPlanner {

    func makePlan(
        recipient: String,
        message: String
    ) -> [InstructionStep] {

        var plan: [InstructionStep] = []

        // --------------------------------------------------
        // 1. Teamsを開く
        // --------------------------------------------------
        plan.append(
            InstructionStep(
                message: "Teamsを開いてください。",
                detectKeywords: [
                    "Teams",
                    "チャット",
                    "チーム",
                    "アクティビティ"
                ],
                minimumMatches: 1,
                manualFinish: false
            )
        )

        // --------------------------------------------------
        // 2. 友達のチャットを開く
        // --------------------------------------------------

        if recipient.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty {

            plan.append(
                InstructionStep(
                    message: "送る相手のチャットを開いてください。",
                    detectKeywords: [
                        "チャット",
                        "メッセージ"
                    ],
                    minimumMatches: 1,
                    manualFinish: false
                )
            )

        } else {

            plan.append(
                InstructionStep(
                    message: "「\(recipient)」さんのチャットを開いてください。",
                    detectKeywords: [
                        recipient
                    ],
                    minimumMatches: 1,
                    manualFinish: false
                )
            )
        }

        // --------------------------------------------------
        // 3. メッセージを入力
        // --------------------------------------------------

        plan.append(
            InstructionStep(
                message:
                    message.isEmpty
                    ? "メッセージ入力欄を押して、文章を入力してください。"
                    : "メッセージ入力欄を押して、次の文章を入力してください。\n「\(message)」",
                detectKeywords: [
                    "メッセージを入力",
                    "メッセージを入力してください",
                    "新しいメッセージ",
                    "メッセージ",
                    "Type a new message"
                ],
                minimumMatches: 1,
                manualFinish: false
            )
        )

        // --------------------------------------------------
        // 4. 送信
        //
        // OCRだけでは「送信前」と「送信後」を
        // 正確に区別しにくいため、
        // ここは最後の案内を出したら自動判定を終了。
        // --------------------------------------------------

        plan.append(
            InstructionStep(
                message: "文章を確認して、「送信」ボタンを押してください。",
                detectKeywords: [
                    "送信",
                    "Send"
                ],
                minimumMatches: 1,
                manualFinish: true
            )
        )

        return plan
    }
}
