import XCTest
@testable import OfflineIntelligenceBenchmarks

final class BenchmarkScorerTests: XCTestCase {
    private var extraction: BenchmarkFixture { BenchmarkSuite.standard[0] }

    func testValidJSONWithWhitespaceAndReorderedKeysPasses() {
        let answer = "  {\"swing_enabled\":false,\"tempo_bpm\":96.0,\"instrument\":\"EightOhEight\"}  \n"
        let score = BenchmarkScorer.score(answer, fixture: extraction)
        XCTAssertTrue(score.passed)
        XCTAssertEqual(score.fraction, 1)
    }

    func testFencedMalformedAndTrailingJSONAreRejected() {
        let answers = ["```json\n{\"instrument\":\"EightOhEight\",\"tempo_bpm\":96,\"swing_enabled\":false}\n```",
                       "{\"instrument\":\"EightOhEight\",", "{} Explanation", "[]", "null"]
        for answer in answers {
            let score = BenchmarkScorer.score(answer, fixture: extraction)
            XCTAssertFalse(score.passed, answer)
            XCTAssertEqual(score.fraction, 0, answer)
        }
    }

    func testMissingWrongAndExtraFieldsFail() {
        let answers = ["{\"instrument\":\"EightOhEight\",\"tempo_bpm\":96}",
                       "{\"instrument\":\"Piano\",\"tempo_bpm\":96,\"swing_enabled\":false}",
                       "{\"instrument\":\"EightOhEight\",\"tempo_bpm\":96,\"swing_enabled\":false,\"extra\":1}"]
        for answer in answers { XCTAssertFalse(BenchmarkScorer.score(answer, fixture: extraction).passed) }
    }

    func testJSONScalarTypesAreStrict() {
        let answers = ["{\"instrument\":\"EightOhEight\",\"tempo_bpm\":\"96\",\"swing_enabled\":false}",
                       "{\"instrument\":\"EightOhEight\",\"tempo_bpm\":96,\"swing_enabled\":0}",
                       "{\"instrument\":\"EightOhEight\",\"tempo_bpm\":true,\"swing_enabled\":false}",
                       "{\"instrument\":\"EightOhEight\",\"tempo_bpm\":96,\"swing_enabled\":\"false\"}"]
        for answer in answers { XCTAssertFalse(BenchmarkScorer.score(answer, fixture: extraction).passed) }
    }

    func testDuplicateKeysIncludingEscapedSpellingsFail() {
        let answers = ["{\"instrument\":\"EightOhEight\",\"tempo_bpm\":96,\"tempo_bpm\":96,\"swing_enabled\":false}",
                       "{\"instrument\":\"EightOhEight\",\"tempo_bpm\":96,\"tempo_\\u0062pm\":96,\"swing_enabled\":false}"]
        for answer in answers { XCTAssertFalse(BenchmarkScorer.score(answer, fixture: extraction).passed) }
    }

    func testIncorrectArithmeticFailsEvenWhenJSONIsValid() {
        let score = BenchmarkScorer.score("{\"voltage_V\":6,\"power_W\":6}", fixture: BenchmarkSuite.standard[2])
        XCTAssertFalse(score.passed)
        XCTAssertEqual(score.checks.first { $0.name == "power_W" }?.passed, false)
    }

    func testCompleteCorrectAnswerAtTokenLimitScoresZero() {
        let answer = "{\"instrument\":\"EightOhEight\",\"tempo_bpm\":96,\"swing_enabled\":false}"
        let score = BenchmarkScorer.score(answer, fixture: extraction, disposition: .tokenLimit)
        XCTAssertFalse(score.passed)
        XCTAssertEqual(score.fraction, 0)
        XCTAssertEqual(score.disposition, .tokenLimit)
    }

    func testGroundedFactChecksFindMissingAndForbiddenFacts() {
        let fixture = BenchmarkSuite.standard[3]
        let good = "Packet 4 reached the receiver, but its acknowledgement was lost. The sender timed out and retried once. The receiver recognized the repeated packet as a duplicate, so it did not deliver it again. This trace describes the supplied simulation."
        XCTAssertTrue(BenchmarkScorer.score(good, fixture: fixture).passed)
        let missing = good.replacingOccurrences(of: "retried once", with: "sent it again")
        XCTAssertFalse(BenchmarkScorer.score(missing, fixture: fixture).passed)
        XCTAssertFalse(BenchmarkScorer.score(good + " It was never received.", fixture: fixture).passed)
    }

    func testCreativeChecksOnlyEnforceLengthLiteralWordsAndFormatting() {
        let fixture = BenchmarkSuite.standard[4]
        let good = "The Sun has tucked its golden shoes away, and the stars are taking over. Curl up, let your adventures rest, and sleep while the moon keeps watch."
        XCTAssertTrue(BenchmarkScorer.score(good, fixture: fixture).passed)
        XCTAssertFalse(BenchmarkScorer.score(good.replacingOccurrences(of: "Sun", with: "sun"), fixture: fixture).passed)
        XCTAssertFalse(BenchmarkScorer.score("Sun sleep", fixture: fixture).passed)
        XCTAssertFalse(BenchmarkScorer.score("- " + good, fixture: fixture).passed)
        XCTAssertFalse(BenchmarkScorer.score(good + " Your assistant approves.", fixture: fixture).passed)
    }

    func testMultilingualExtractionRequiresTranslatedScalarValues() {
        let fixture = BenchmarkSuite.standard[5]
        XCTAssertTrue(BenchmarkScorer.score("{\"city\":\"Madrid\",\"count\":3,\"transport\":\"train\"}", fixture: fixture).passed)
        XCTAssertFalse(BenchmarkScorer.score("{\"city\":\"Madrid\",\"count\":\"tres\",\"transport\":\"tren\"}", fixture: fixture).passed)
    }

    func testMediansHandleUnsortedOddEvenAndInvalidSamples() {
        XCTAssertEqual(BenchmarkStatistics.median([12, 1, 3]), 3)
        XCTAssertEqual(BenchmarkStatistics.median([9, 1, 3, 5]), 4)
        XCTAssertEqual(BenchmarkStatistics.median([.nan, 7, .infinity]), 7)
        XCTAssertNil(BenchmarkStatistics.median([]))
        XCTAssertNil(BenchmarkStatistics.median([.nan, .infinity]))
    }
}
