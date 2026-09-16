import XCTest
@testable import DeviceFarmScheduler

/// Every case here is an input that makes the *built-in* operator trap.
/// The assertions are exact values rather than "doesn't crash", because
/// "doesn't crash" is satisfied by a function that returns garbage.
final class SaturatingArithmeticTests: XCTestCase {

    func testAdditionSaturatesInBothDirections() {
        XCTAssertEqual(Saturating.add(Int.max, 1), Int.max)
        XCTAssertEqual(Saturating.add(Int.max, Int.max), Int.max)
        XCTAssertEqual(Saturating.add(Int.min, -1), Int.min)
        XCTAssertEqual(Saturating.add(Int.min, Int.min), Int.min)
        // Non-overflowing arithmetic must still be exact.
        XCTAssertEqual(Saturating.add(7, -12), -5)
        XCTAssertEqual(Saturating.add(Int.max, Int.min), -1)
    }

    func testSubtractionSaturatesInBothDirections() {
        XCTAssertEqual(Saturating.subtract(Int.min, 1), Int.min)
        XCTAssertEqual(Saturating.subtract(Int.max, -1), Int.max)
        XCTAssertEqual(Saturating.subtract(Int.max, Int.min), Int.max)
        XCTAssertEqual(Saturating.subtract(5, 9), -4)
    }

    func testMultiplicationSaturatesWithCorrectSign() {
        XCTAssertEqual(Saturating.multiply(Int.max, 2), Int.max)
        XCTAssertEqual(Saturating.multiply(Int.max, -2), Int.min)
        XCTAssertEqual(Saturating.multiply(Int.min, 2), Int.min)
        // Int.min * -1 overflows high; this is the case a naive `abs` gets wrong.
        XCTAssertEqual(Saturating.multiply(Int.min, -1), Int.max)
        XCTAssertEqual(Saturating.multiply(0, Int.max), 0)
        XCTAssertEqual(Saturating.multiply(-3, -4), 12)
    }

    func testDivisionHandlesBothTrappingInputs() {
        // Division by zero.
        XCTAssertEqual(Saturating.divide(5, by: 0), Int.max)
        XCTAssertEqual(Saturating.divide(-5, by: 0), Int.min)
        XCTAssertEqual(Saturating.divide(0, by: 0), Int.max)
        // Int.min / -1, whose true value is Int.max + 1.
        XCTAssertEqual(Saturating.divide(Int.min, by: -1), Int.max)
        // Ordinary division is unchanged, including truncation toward zero.
        XCTAssertEqual(Saturating.divide(7, by: 2), 3)
        XCTAssertEqual(Saturating.divide(-7, by: 2), -3)
    }

    func testRemainderHandlesBothTrappingInputs() {
        XCTAssertEqual(Saturating.remainder(5, 0), 0)
        XCTAssertEqual(Saturating.remainder(Int.min, -1), 0)
        XCTAssertEqual(Saturating.remainder(7, 3), 1)
        XCTAssertEqual(Saturating.remainder(-7, 3), -1)
    }

    func testIntConversionHandlesNaNInfinityAndRange() {
        XCTAssertEqual(Saturating.int(Double.nan), Int.min)
        XCTAssertEqual(Saturating.int(Double.infinity), Int.max)
        XCTAssertEqual(Saturating.int(-Double.infinity), Int.min)
        // 2^64, far outside Int's range in both directions.
        XCTAssertEqual(Saturating.int(1.8446744073709552e19), Int.max)
        XCTAssertEqual(Saturating.int(-1.8446744073709552e19), Int.min)
        // Exactly the Double that Int.max rounds up to must not convert.
        XCTAssertEqual(Saturating.int(Double(Int.max)), Int.max)
        XCTAssertEqual(Saturating.int(Double(Int.min)), Int.min)
        // In-range values convert normally, truncating toward zero.
        XCTAssertEqual(Saturating.int(3.9), 3)
        XCTAssertEqual(Saturating.int(-3.9), -3)
    }

    func testIntConversionRespectsExplicitRange() {
        XCTAssertEqual(Saturating.int(500, clampedTo: 0...100), 100)
        XCTAssertEqual(Saturating.int(-500, clampedTo: 0...100), 0)
        XCTAssertEqual(Saturating.int(Double.nan, clampedTo: 0...100), 0)
        XCTAssertEqual(Saturating.int(42.7, clampedTo: 0...100), 42)
    }

    func testClampAndSum() {
        XCTAssertEqual(Saturating.clamp(-5, to: 0...10), 0)
        XCTAssertEqual(Saturating.clamp(50, to: 0...10), 10)
        XCTAssertEqual(Saturating.clamp(5, to: 0...10), 5)
        XCTAssertEqual(Saturating.sum([1, 2, 3]), 6)
        XCTAssertEqual(Saturating.sum([Int.max, Int.max]), Int.max)
        XCTAssertEqual(Saturating.sum([Int]()), 0)
    }

    /// The saturating helpers are only worth anything if the public API actually
    /// routes hostile values through them. This drives a real sizing call with
    /// costs that would overflow a plain `*` and asserts it returns a value.
    func testPublicAPISurvivesOverflowingCostInputs() {
        let histogram = ArrivalHistogram(counts: [0, Int.max, Int.max])
        let model = PoolCostModel(
            idleHostCostPerInterval: Int.max,
            coldStartCostPerJob: Int.max
        )
        let result = PoolSizer.size(histogram: histogram, model: model)
        XCTAssertFalse(result.curve.isEmpty)
        XCTAssertGreaterThanOrEqual(result.recommendedDepth, 0)
        XCTAssertLessThanOrEqual(result.recommendedDepth, histogram.maxObserved)
    }
}
