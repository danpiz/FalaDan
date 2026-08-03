import Foundation
import Testing

@testable import FalaDan

/// Regression fixture: a real response from Groq's `qwen/qwen3.6-27b`, captured
/// verbatim while benchmarking cleanup models against FalaDan's own prompt.
///
/// 4,175 characters, of which the answer is the last 55. Every other character is
/// the model narrating its own reasoning — including an echo of the user's
/// transcript. Before stripping, all of it would have been pasted at the cursor.
struct CleanupReasoningFixtureTests {
    /// Captured 2026-08-03. Do not tidy: its value is being exactly what a
    /// reasoning model actually returned, awkward whitespace and all.
    static let qwenResponse = #"""

<think>
Thinking Process:
1.  **Analyze the Input:**
   - Input: `<RAW_STT_OUTPUT> um so the meeting is at three pm scratch that four pm and their going to deploy it </RAW_STT_OUTPUT>`
   - Key elements:
     - Fillers: "um", "so" (can keep "so" if it flows, but usually remove "um")
     - Backtrack: "scratch that" -> cancel "three pm", keep "four pm"
     - Homophone/Grammar: "their going to" -> "they're going to"
     - Punctuation: Needs sentence structure.
   - Constraints: Fix errors, add punctuation, remove fillers, honor backtracks, preserve voice/content, output plain text only.

2.  **Apply Cleanup Rules:**
   - Remove "um"
   - "so the meeting is at three pm scratch that four pm" -> "So the meeting is at four pm." (or just "The meeting is at four pm.") I'll keep "So" if it's natural, but usually "So the meeting is at four pm." is fine. Actually, "so" is often a filler here. I'll keep it as "The meeting is at four pm." or "So the meeting is at four pm." Let's stick closely to the original: "The meeting is at four pm."
   - "and their going to deploy it" -> "and they're going to deploy it."
   - Combine: "The meeting is at four pm, and they're going to deploy it."

   Let's refine:
   Original: "um so the meeting is at three pm scratch that four pm and their going to deploy it"
   Cleaned: "The meeting is at four pm, and they're going to deploy it."

   Check constraints:
   - Fix homophones: their -> they're. Done.
   - Add punctuation: Done.
   - Remove fillers: um, so (optional, but "so" is often kept if it starts a sentence, I'll drop it for cleanliness or keep it: "So the meeting is at four pm, and they're going to deploy it." Both work. I'll go with "The meeting is at four pm, and they're going to deploy it.")
   - Honor backtracks: scratch that -> removed "three pm". Done.
   - Format: plain text.
   - No extra text.

   Final check of the text: "The meeting is at four pm, and they're going to deploy it."
   Matches all rules. Output matches exactly.✅
   One minor point: "three pm" -> "3 pm" per rule "Specific values (dates, times, decimals, version numbers) as numerals". So "4 pm".
   "The meeting is at 4 pm, and they're going to deploy it."
   Ready.✅
   Output matches exactly. No extra words. Plain text.
   Proceed. 
   Output: The meeting is at 4 pm, and they're going to deploy it. 
   Wait, let's verify the "so" removal. The prompt says "Remove fillers ("um", "uh")". "so" isn't explicitly listed but often treated as filler. I'll keep it if it feels natural, but dropping it is safer. I'll stick with "The meeting is at 4 pm, and they're going to deploy it."
   All good. 
   Output generation. 
   [Self-Correction/Verification during thought]
   Rule: "Specific values (dates, times, decimals, version numbers) as numerals" -> 4 pm.
   Rule: "Honor backtracks... drop the cancelled part, keep only the correction." -> three pm dropped.
   Rule: "Fix transcription errors, including homophones" -> their -> they're.
   Result: The meeting is at 4 pm, and they're going to deploy it.
   Matches perfectly. Output matches constraint. No markdown. Plain text.✅
   Proceeds. 
   Output Generation. 
   `The meeting is at 4 pm, and they're going to deploy it.` (without backticks)
   Done. 
   [Output Generation] -> The meeting is at 4 pm, and they're going to deploy it. 
   (Note: I will ensure absolutely no extra text is generated.) 
   Final Check of the prompt: "Output the cleaned text only: No surrounding quotes. No preamble or labels... No markdown styling... Plain text or simple list bullets only."
   All constraints met.✅
   Output matches. 
   Proceeds. 
   [Output] The meeting is at 4 pm, and they're going to deploy it. 
   (Self-Correction/Refinement during thought: Should I keep "So"? "So the meeting is at 4 pm, and they're going to deploy it." is fine too. I'll stick to dropping it for conciseness as it's a filler starter. Either is fine. I'll output exactly: The meeting is at 4 pm, and they're going to deploy it.) 
   Done. 
   [Output Generation] -> The meeting is at 4 pm, and they're going to deploy it. 
   *(Done.)*
</think>

The meeting is at 4 pm, and they're going to deploy it.
"""#

    private var body: Data {
        try! JSONSerialization.data(
            withJSONObject: ["choices": [["message": ["content": Self.qwenResponse]]]])
    }

    @Test func extractsOnlyTheAnswerFromARealReasoningResponse() throws {
        let result = try CleanupClient.parseResponse(body)
        #expect(result == "The meeting is at 4 pm, and they're going to deploy it.")
    }

    @Test func noReasoningSurvivesIntoThePastedText() throws {
        let result = try CleanupClient.parseResponse(body)
        #expect(!result.lowercased().contains("<think"))
        #expect(!result.contains("Thinking Process"))
        #expect(!result.contains("RAW_STT_OUTPUT"))
        // The whole point: 4k characters in, one sentence out.
        #expect(result.count < 100)
    }
}
