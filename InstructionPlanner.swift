```swift
import Foundation

struct InstructionStep: Identifiable {

    let id = UUID()

    let message: String

    let detectKeywords: [String]

    let minimumMatches: Int

    let manualFinish: Bool
}

@MainActor
final class InstructionPlanner {

    func makePlan(
        for supportContent: String
    ) -> [InstructionStep] {

        let normalized =
            normalize(
                supportContent
            )

        guard normalized.contains("teams") else {

            return [
                InstructionStep(
                    message:
                        "現在はTeamsの支援に対応しています。「Teamsで田中さんにメッセージを送りたい」のように入力してください。",
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

        // --------------------------------------------------------
        // STEP 0
        // 「Teamsを開いてください」
        //
        // ★ここはTeamsだけを見ればよい
        // 「チャット」などを同時に要求しない
        // --------------------------------------------------------

        let step1 =
            InstructionStep(
                message:
                    "Teamsを開いてください。",
                detectKeywords: [
                    "Teams",
                    "Microsoft Teams"
                ],
                minimumMatches: 1,
                manualFinish: false
            )

        // --------------------------------------------------------
        // STEP 1
        // 相手のチャットを開いてもらう
        //
        // 相手の名前 + チャット系ワード
        // のどちらか一方だけでもOCR揺れに対応できるよう、
        // 最低1個で判定する
        //
        // 実際のチャット画面になったかは
        // 「画面変更 + 連続一致」で確認する
        // --------------------------------------------------------

        let step2 =
            InstructionStep(
                message:
                    "「\(recipient)」さんのチャットを開いてください。",
                detectKeywords: [
                    recipient,
                    "チャット",
                    "メッセージ",
                    "Chat"
                ],
                minimumMatches: 1,
                manualFinish: false
            )

        // --------------------------------------------------------
        // STEP 2
        // 最後は手動
        // --------------------------------------------------------

        let step3 =
            InstructionStep(
                message:
                    "メッセージ入力欄を押して、送りたい文章を入力してください。入力したら「送信」を押してください。",
                detectKeywords: [],
                minimumMatches: 0,
                manualFinish: true
            )

        return [
            step1,
            step2,
            step3
        ]
    }

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
                        options: [.caseInsensitive]
                    )
            else {
                continue
            }

            let textRange =
                NSRange(
                    text.startIndex..<text.endIndex,
                    in: text
                )

            guard let match =
                    regex.firstMatch(
                        in: text,
                        range: textRange
                    )
            else {
                continue
            }

            guard match.numberOfRanges > 1 else {
                continue
            }

            let recipientRange =
                match.range(
                    at: 1
                )

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

            recipient =
                recipient.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )

            return recipient
        }

        return ""
    }

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
```
