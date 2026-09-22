import Foundation

struct InstructionStep {
    let detectKeyword: String
    let message: String
}

struct InstructionPlanner {

    func plan(for request: String) -> [InstructionStep] {
        let text = request.lowercased()

        if text.contains("写真")
            || text.contains("画像")
            || text.contains("孫") {

            return [
                InstructionStep(
                    detectKeyword: "LINE",
                    message: "LINEを開いてください。"
                ),

                InstructionStep(
                    detectKeyword: "孫",
                    message: "「孫」のトークを開いてください。"
                ),

                InstructionStep(
                    detectKeyword: "＋",
                    message: "「＋」ボタンを押してください。"
                ),

                InstructionStep(
                    detectKeyword: "写真",
                    message: "送りたい写真を選んでください。"
                )
            ]
        }

        if text.contains("地図")
            || text.contains("駅") {

            return [
                InstructionStep(
                    detectKeyword: "地図",
                    message: "地図アプリを開いてください。"
                ),

                InstructionStep(
                    detectKeyword: "検索",
                    message: "検索欄を押してください。"
                )
            ]
        }

        if text.contains("市役所")
            || text.contains("行政")
            || text.contains("申請")
            || text.contains("手続き") {

            return [
                InstructionStep(
                    detectKeyword: "Safari",
                    message: "インターネットを開いてください。"
                ),

                InstructionStep(
                    detectKeyword: "申請",
                    message: "「申請・手続き」を押してください。"
                ),

                InstructionStep(
                    detectKeyword: "本人確認",
                    message: "本人確認画面です。個人情報はご自身で入力してください。"
                )
            ]
        }

        return [
            InstructionStep(
                detectKeyword: "",
                message: "画面を確認しています。次の操作を案内します。"
            )
        ]
    }
}

enum PrivacyGuard {

    static func isSensitive(_ text: String) -> Bool {
        let keywords = [
            "パスワード",
            "暗証番号",
            "口座番号",
            "カード番号",
            "セキュリティコード",
            "マイナンバー",
            "本人確認",
            "生年月日",
            "ログイン"
        ]

        return keywords.contains {
            text.localizedCaseInsensitiveContains($0)
        }
    }
}
