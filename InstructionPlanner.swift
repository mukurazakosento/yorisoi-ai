import Foundation

struct InstructionStep: Identifiable {
    let id = UUID()

    let message: String

    // 画面確認に使うOCR候補
    let detectKeywords: [String]

    // 必要な一致数
    let minimumMatches: Int

    // trueならここで自動判定終了
    let manualFinish: Bool
}

@MainActor
final class InstructionPlanner {

    func makePlan(for supportContent: String) -> [InstructionStep] {

        let normalizedContent = normalize(supportContent)

        // --------------------------------------------------
        // Teamsで○○さんにメッセージを送りたい
        // --------------------------------------------------

        guard normalizedContent.contains("teams") else {

            return [
                InstructionStep(
                    message: "現在はTeamsの支援に対応しています。支援内容に「Teamsで○○さんにメッセージを送りたい」と入力してください。",
                    detectKeywords: [],
                    minimumMatches: 0,
                    manualFinish: true
                )
            ]
        }

        let recipient = extractRecipient(
            from: supportContent
        )

        if recipient.isEmpty {

            return [
                InstructionStep(
                    message: "支援内容に、送る相手の名前を入れてください。例：「Teamsで田中さんにメッセージを送りたい」",
                    detectKeywords: [],
                    minimumMatches: 0,
                    manualFinish: true
                )
            ]
        }

        // --------------------------------------------------
        // Teamsを開く
        // --------------------------------------------------

        var plan: [InstructionStep] = []

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
        // 相手のチャットを開く
        // --------------------------------------------------

        plan.append(
            InstructionStep(
                message: "「\(recipient)」さんのチャットを開いてください。",
                detectKeywords: [
                    recipient,
                    "チャット",
                    "メッセージ"
                ],
                minimumMatches: 1,
                manualFinish: false
            )
        )

        // --------------------------------------------------
        // メッセージ入力
        // --------------------------------------------------

        plan.append(
            InstructionStep(
                message: "メッセージ入力欄を押して、送りたい文章を入力してください。",
                detectKeywords: [
                    "新しいメッセージ",
                    "メッセージ",
                    "入力",
                    "Type a new message"
                ],
                minimumMatches: 1,
                manualFinish: false
            )
        )

        // --------------------------------------------------
        // 送信
        //
        // 最後はユーザー自身が送信する。
        // 自動的に完了扱いにはしない。
        // --------------------------------------------------

        plan.append(
            InstructionStep(
                message: "文章を確認して、「送信」ボタンを押してください。",
                detectKeywords: [],
                minimumMatches: 0,
                manualFinish: true
            )
        )

        return plan
    }

    // MARK: - Recipient

    private func extractRecipient(
        from text: String
    ) -> String {

        // 「Teamsで田中さんにメッセージを送りたい」
        // を想定

        let patterns = [
            #"Teamsで(.+?)さんにメッセージ"#,
            #"Teamsで(.+?)にメッセージ"#,
            #"Teamsで(.+?)さんに"#,
            #"Teamsで(.+?)に"#,
            #"teamsで(.+?)さんにメッセージ"#,
            #"teamsで(.+?)にメッセージ"#
        ]

        for pattern in patterns {

            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else {
                continue
            }

            let range = NSRange(
                text.startIndex..<text.endIndex,
                in: text
            )

            if let match = regex.firstMatch(
                in: text,
                range: range
            ) {

                guard match.numberOfRanges > 1 else {
                    continue
                }

                let recipientRange =
                    match.range(at: 1)

                guard let swiftRange =
                        Range(
                            recipientRange,
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

                return recipient
            }
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
