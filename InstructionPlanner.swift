import Foundation

struct InstructionStep: Identifiable {
    let id = UUID()
    let message: String

    // OCRで、この文字が画面に出てきたら次のステップへ進む
    let detectKeyword: String
}

@MainActor
final class InstructionPlanner {

    func makePlan(for goal: String) -> [InstructionStep] {

        let normalizedGoal = goal
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .lowercased()

        // --------------------------------------------------
        // 孫に写真を送りたい
        // --------------------------------------------------
        if normalizedGoal.contains("孫")
            && (normalizedGoal.contains("写真")
                || normalizedGoal.contains("画像")
                || normalizedGoal.contains("送")) {

            return [
                InstructionStep(
                    message: "LINEを開いてください。",
                    detectKeyword: "LINE"
                ),

                InstructionStep(
                    message: "「孫」のトークを開いてください。",
                    detectKeyword: "孫"
                ),

                InstructionStep(
                    message: "「＋」ボタンを押してください。",
                    detectKeyword: "+"
                ),

                InstructionStep(
                    message: "「写真」を選んでください。",
                    detectKeyword: "写真"
                ),

                InstructionStep(
                    message: "送りたい写真を選んでください。",
                    detectKeyword: "選択"
                ),

                InstructionStep(
                    message: "「送信」ボタンを押してください。",
                    detectKeyword: "送信"
                )
            ]
        }

        // --------------------------------------------------
        // 写真を送りたい
        // --------------------------------------------------
        if normalizedGoal.contains("写真")
            && (normalizedGoal.contains("送")
                || normalizedGoal.contains("送り")) {

            return [
                InstructionStep(
                    message: "LINEを開いてください。",
                    detectKeyword: "LINE"
                ),

                InstructionStep(
                    message: "送りたい相手のトークを開いてください。",
                    detectKeyword: "トーク"
                ),

                InstructionStep(
                    message: "「＋」ボタンを押してください。",
                    detectKeyword: "+"
                ),

                InstructionStep(
                    message: "「写真」を選んでください。",
                    detectKeyword: "写真"
                ),

                InstructionStep(
                    message: "送りたい写真を選んでください。",
                    detectKeyword: "選択"
                ),

                InstructionStep(
                    message: "「送信」ボタンを押してください。",
                    detectKeyword: "送信"
                )
            ]
        }

        // --------------------------------------------------
        // LINEでメッセージを送りたい
        // --------------------------------------------------
        if normalizedGoal.contains("line")
            && (normalizedGoal.contains("メッセージ")
                || normalizedGoal.contains("メッセージを送")
                || normalizedGoal.contains("連絡")) {

            return [
                InstructionStep(
                    message: "LINEを開いてください。",
                    detectKeyword: "LINE"
                ),

                InstructionStep(
                    message: "メッセージを送りたい相手のトークを開いてください。",
                    detectKeyword: "トーク"
                ),

                InstructionStep(
                    message: "メッセージを入力してください。",
                    detectKeyword: "メッセージ"
                ),

                InstructionStep(
                    message: "「送信」ボタンを押してください。",
                    detectKeyword: "送信"
                )
            ]
        }

        // --------------------------------------------------
        // LINEを開きたい
        // --------------------------------------------------
        if normalizedGoal.contains("line") {

            return [
                InstructionStep(
                    message: "LINEを開いてください。",
                    detectKeyword: "LINE"
                )
            ]
        }

        // --------------------------------------------------
        // 電話をかけたい
        // --------------------------------------------------
        if normalizedGoal.contains("電話")
            || normalizedGoal.contains("電話をかけ") {

            return [
                InstructionStep(
                    message: "「電話」アプリを開いてください。",
                    detectKeyword: "電話"
                ),

                InstructionStep(
                    message: "電話をかけたい相手を選んでください。",
                    detectKeyword: "連絡先"
                ),

                InstructionStep(
                    message: "電話番号を確認して、発信ボタンを押してください。",
                    detectKeyword: "発信"
                )
            ]
        }

        // --------------------------------------------------
        // Googleで検索したい
        // --------------------------------------------------
        if normalizedGoal.contains("検索")
            || normalizedGoal.contains("調べ") {

            return [
                InstructionStep(
                    message: "SafariまたはGoogleを開いてください。",
                    detectKeyword: "Safari"
                ),

                InstructionStep(
                    message: "検索したい内容を入力してください。",
                    detectKeyword: "検索"
                ),

                InstructionStep(
                    message: "検索結果が表示されたら、目的のページを選んでください。",
                    detectKeyword: "検索結果"
                )
            ]
        }

        // --------------------------------------------------
        // それ以外
        // --------------------------------------------------
        return [
            InstructionStep(
                message: "まず、目的のアプリを開いてください。",
                detectKeyword: ""
            )
        ]
    }
}
