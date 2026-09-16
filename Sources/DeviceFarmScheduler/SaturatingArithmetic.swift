/// Integer arithmetic that saturates instead of trapping.
///
/// A scheduler ingests numbers it does not control: service costs parsed from a
/// CI config, byte counts reported by a hypervisor, cost weights typed into a
/// dashboard. Every one of `+`, `*`, `/`, `%` and `Int(Double)` can trap on
/// hostile input, and a scheduler that crashes is worse than one that mis-sizes
/// a pool. Every arithmetic operation in this module that touches externally
/// supplied values routes through here.
///
/// The saturation direction is always the mathematically correct one: an
/// overflowing positive product saturates to `Int.max`, a negative one to
/// `Int.min`. Ceilings are derived from `Int.max` rather than a 64-bit literal,
/// so the behaviour is correct on 32-bit `Int` platforms too.
public enum Saturating {

    /// `a + b`, clamped to the representable range instead of trapping.
    @inlinable
    public static func add(_ a: Int, _ b: Int) -> Int {
        let (value, overflow) = a.addingReportingOverflow(b)
        guard overflow else { return value }
        // Overflow in an addition can only run off the end that `b` points to.
        return b > 0 ? Int.max : Int.min
    }

    /// `a - b`, clamped to the representable range instead of trapping.
    @inlinable
    public static func subtract(_ a: Int, _ b: Int) -> Int {
        let (value, overflow) = a.subtractingReportingOverflow(b)
        guard overflow else { return value }
        // Subtracting a negative overflows high; subtracting a positive, low.
        return b < 0 ? Int.max : Int.min
    }

    /// `a * b`, clamped to the representable range instead of trapping.
    @inlinable
    public static func multiply(_ a: Int, _ b: Int) -> Int {
        let (value, overflow) = a.multipliedReportingOverflow(by: b)
        guard overflow else { return value }
        // Zero can never overflow, so both operands are non-zero here and the
        // sign of the true product is decided by whether the signs agree.
        return (a > 0) == (b > 0) ? Int.max : Int.min
    }

    /// `a / b` that never traps.
    ///
    /// Two inputs trap for the built-in operator and both are handled here:
    /// division by zero (saturates in the direction of `a`'s sign) and
    /// `Int.min / -1`, whose true value is `Int.max + 1`.
    @inlinable
    public static func divide(_ a: Int, by b: Int) -> Int {
        guard b != 0 else { return a >= 0 ? Int.max : Int.min }
        let (value, overflow) = a.dividedReportingOverflow(by: b)
        // With `b != 0` the only remaining overflow is `Int.min / -1`.
        return overflow ? Int.max : value
    }

    /// `a % b` that never traps.
    ///
    /// Returns `0` for a zero divisor, matching the "no work to distribute"
    /// reading every caller in this module wants, and `0` for `Int.min % -1`,
    /// which is the mathematically correct remainder.
    @inlinable
    public static func remainder(_ a: Int, _ b: Int) -> Int {
        guard b != 0 else { return 0 }
        let (value, overflow) = a.remainderReportingOverflow(dividingBy: b)
        return overflow ? 0 : value
    }

    /// `Int(d)` that never traps on NaN, ±infinity, or an out-of-range value.
    ///
    /// `Int(Double)` traps on all three. NaN has no ordering and therefore no
    /// defensible numeric answer, so it is mapped to `range.lowerBound` and the
    /// choice is left to the caller's range. Callers converting a *cost* should
    /// use ``cost(_:)`` instead, which resolves NaN in the safe direction for
    /// that meaning.
    @inlinable
    public static func int(
        _ d: Double,
        clampedTo range: ClosedRange<Int> = Int.min...Int.max
    ) -> Int {
        guard !d.isNaN else { return range.lowerBound }
        guard d.isFinite else { return d > 0 ? range.upperBound : range.lowerBound }

        // Compare in Double space against the range bounds before converting.
        // `Double(Int.max)` rounds *up* to 2^63, so `d < upper` guarantees the
        // conversion is in range; `Double(Int.min)` is exactly -2^63.
        let lower = Double(range.lowerBound)
        let upper = Double(range.upperBound)
        if d <= lower { return range.lowerBound }
        if d >= upper { return range.upperBound }
        return Int(d)
    }

    /// Converts a non-negative *cost* from `Double` without trapping.
    ///
    /// Differs from ``int(_:clampedTo:)`` in exactly one place, and it is the
    /// place that matters: an unusable input (NaN) resolves to `Int.max`, not to
    /// zero. A cost arriving as NaN means the caller does not know what this
    /// costs, and the one reading a scheduler must never take from that is
    /// "free" — that would make the unknown option look like the cheapest one
    /// and get it chosen. Infinity and out-of-range values clamp the same way;
    /// negatives clamp to zero, since a negative cost is a modelling error.
    @inlinable
    public static func cost(_ d: Double) -> Int {
        guard !d.isNaN else { return Int.max }
        return int(d, clampedTo: 0...Int.max)
    }

    /// Clamps `value` into `range` without trapping on an inverted range.
    @inlinable
    public static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        if value < range.lowerBound { return range.lowerBound }
        if value > range.upperBound { return range.upperBound }
        return value
    }

    /// Sums a sequence of `Int` without trapping on overflow.
    @inlinable
    public static func sum<S: Sequence>(_ values: S) -> Int where S.Element == Int {
        values.reduce(0) { add($0, $1) }
    }
}
