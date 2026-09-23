import Foundation

struct InstructionStep: Identifiable {
    let id = UUID()

    let message: String

    // この候補のうち何個一致したら
    // 「目的の画面」と判断するか
    let detectKeywords: [String]

    let minimumMatches: Int

    // trueなら、この通知を出して自動判定終了
    let manualFinish: Bool
}

@MainActor
final class InstructionPlanner {

    func makePlan(
        for supportContent: String
    ) -> [InstructionStep] {

        let normalized =
            normalize(supportContent)

        // --------------------------------------------------
        // Teams支援のみ対応
        // --------------------------------------------------

        guard normalized.contains("teams") else {

            return [
                InstructionStep(
                    message:
                        "現在はTeamsの支援に対応しています。例：「Teamsで田中さんにメッセージを送りたい」",
                    detectKeywords: [],
                    minimumMatches: 0,
                    manualFinish: true
                )
            ]
        }

        let recipient =
            extractRecipient(
                from: supportContent
            )

        guard !recipient.isEmpty else {

            return [
                InstructionStep(
                    message:
                        "送る相手の名前を入れてください。例：「Teamsで田中さんにメッセージを送りたい」",
                    detectKeywords: [],
                    minimumMatches: 0,
                    manualFinish: true
                )
            ]
        }

        // --------------------------------------------------
        // STEP 0
        // Teamsを開く
        //
        // Teamsという文字がOCRで取れない場合もあるので、
        // Teamsのホーム画面に出やすい文字を候補にする。
        // どれか1つでOK。
        // --------------------------------------------------

        let openTeams =
            InstructionStep(
                message:
                    "Teamsを開いてください。",
                detectKeywords: [
                    "Teams",
                    "Microsoft Teams",
                    "チャット",
                    "アクティビティ",
                    "チーム",
                    "予定表"
                ],
                minimumMatches: 1,
                manualFinish: false
            )

        // --------------------------------------------------
        // STEP 1
        // 相手のチャットを開く
        //
        // 相手の名前を必須条件にする。
        // --------------------------------------------------

        let openChat =
            InstructionStep(
                message:
                    "「\(recipient)」さんのチャットを開いてください。",
                detectKeywords: [
                    recipient,
                    "チャット",
                    "メッセージ"
                ],
                minimumMatches: 2,
                manualFinish: false
            )

        // --------------------------------------------------
        // STEP 2
        // メッセージ入力
        // --------------------------------------------------

        let inputMessage =
            InstructionStep(
                message:
                    "メッセージ入力欄を押して、送りたい文章を入力してください。",
                detectKeywords: [
                    "メッセージ",
                    "送信",
                    "入力",
                    "新しいメッセージ"
                ],
                minimumMatches: 2,
                manualFinish: false
            )

        // --------------------------------------------------
        // STEP 3
        // 送信
        //
        // ここはユーザーが手動で送信。
        // 自動で完了させない。
        // --------------------------------------------------

        let sendMessage =
            InstructionStep(
                message:
                    "文章を確認して、「送信」ボタンを押してください。",
                detectKeywords: [],
                minimumMatches: 0,
                manualFinish: true
            )

        return [
            openTeams,
            openChat,
            inputMessage,
            sendMessage
        ]
    }

    // MARK: - Extract Recipient

    private func extractRecipient(
        from text: String
    ) -> String {

        let patterns = [

            #"Teamsで(.+?)さんにメッセージ"#,

            #"Teamsで(.+?)にメッセージ"#,

            #"Teamsで(.+?)さんに"#,

            #"Teamsで(.+?)に"#,

            #"teamsで(.+?)さんにメッセージ"#,

            #"teamsで(.+?)にメッセージ"#
        ]

        for pattern in patterns {

            guard let regex =
                    try? NSRegularExpression(
                        pattern: pattern,
                        options: [
                            .caseInsensitive
                        ]
                    )
            else {
                continue
            }

            let range =
                NSRange(
                    text.startIndex..<text.endIndex,
                    in: text
                )

            guard let match =
                    regex.firstMatch(
                        in: text,
                        range: range
                    )
            else {
                continue
            }

            guard match.numberOfRanges > 1 else {
                continue
            }

            let range =
                match.range(
                    at: 1
                )

            guard let swiftRange =
                    Range(
                        range,
                        in: text
                    )
            else {
                continue
            }

            var recipient =
                String(
                    text[swiftRange]
                )

            recipient =
                recipient.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )

            recipient =
                recipient.replacingOccurrences(
                    of: "さん",
                    with: ""
                )

            recipient =
                recipient.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )

            return recipient
        }

        return ""
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
