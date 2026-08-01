@testable import FalaDan
import Testing

struct TranscriptionFormatterTests {
    @Test func preserveCaseReplacementRunsAfterCasualLowercase() {
        let options = TranscriptionFormatter.Options(
            replacementRules: [
                ReplacementRule(
                    find: "mini whisper",
                    replace: "FalaDan",
                    preserveCase: true
                ),
            ],
            capitalization: .casual,
            autoParagraph: false,
            dropTrailingPunctuation: false,
            spokenSymbolsEnabled: false,
            appendTrailingSpace: false
        )

        #expect(TranscriptionFormatter.format("I use mini whisper daily", options: options) == "i use FalaDan daily")
    }

    @Test func ordinaryReplacementStillFeedsFormatting() {
        let options = TranscriptionFormatter.Options(
            replacementRules: [ReplacementRule(find: "mini whisper", replace: "FalaDan")],
            capitalization: .casual,
            autoParagraph: false,
            dropTrailingPunctuation: false,
            spokenSymbolsEnabled: false,
            appendTrailingSpace: false
        )

        #expect(TranscriptionFormatter.format("I use mini whisper daily", options: options) == "i use faladan daily")
    }
}
