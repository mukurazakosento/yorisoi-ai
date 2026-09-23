import Foundation

struct InstructionStep: Identifiable {
    let id = UUID()

    let message: String

    // 画面がこの条件を満たしたら次の通知へ進む
    let detectKeywords: [String]

    // 候補のうち必要な一致数
    let minimumMatches: Int

    // 最後の送信案内
    let manualFinish: Bool
}

@MainActor
final class InstructionPlanner {

    func makePlan(
        recipient: String,
        message: String
    ) -> [InstructionStep] {

        return [

            // ---------------------------------------------
            // STEP 0
            // Teams画面になったことを確認する
            // ---------------------------------------------

            InstructionStep(
                message: "Teamsを開いてください。",
                detectKeywords: [
                    "Teams",
                    "アクティビティ",
                    "チャット",
                    "チーム"
                ],
                minimumMatches: 2,
                manualFinish: false
            ),

            // ---------------------------------------------
            // STEP 1
            // 相手のチャット画面になったことを確認
            // ---------------------------------------------

            InstructionStep(
                message: "「\(recipient)」さんのチャットを開いてください。",
                detectKeywords: [
                    recipient,
                    "チャット",
                    "メッセージ"
                ],
                minimumMatches: 2,
                manualFinish: false
            ),

            // ---------------------------------------------
            // STEP 2
            // 入力した文章を確認
            // ---------------------------------------------

            InstructionStep(
                message:
                    "メッセージ入力欄を押して、次の文章を入力してください。\n「\(message)」",
                detectKeywords: [
                    message,
                    "送信",
                    "メッセージ"
                ],
                minimumMatches: 2,
                manualFinish: false
            ),

            // ---------------------------------------------
            // STEP 3
            // 送信
            //
            // ここから先はAI/OCRで自動的に進めない
            // ---------------------------------------------

            InstructionStep(
                message: "文章を確認して、「送信」ボタンを押してください。",
                detectKeywords: [],
                minimumMatches: 0,
                manualFinish: true
            )
        ]
    }
}
