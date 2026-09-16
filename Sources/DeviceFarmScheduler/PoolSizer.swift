/// How deep to keep the warm pool.
///
/// The textbook move is to assume Poisson arrivals and solve for a depth. PR
/// traffic is not Poisson: it is correlated with the workday, with the release
/// train, and — increasingly the dominant term — with agent fan-out, where one
/// human action enqueues twenty runs at once. Fitting a distribution whose
/// defining assumption is independence to a workload whose defining feature is
/// correlated bursts produces a confident number that is wrong in exactly the
/// tail you are sizing for.
///
/// So this sizer does not fit anything. It takes the observed histogram of
/// concurrent arrivals straight from the last N days of CI and evaluates the
/// real cost function at every candidate depth. That is a worse answer in a
/// paper and a better one in production, and it has the additional property of
/// being auditable: the curve is a list of integers a platform lead can put in
/// a doc, not a parameter fit somebody has to take on faith.
public struct ArrivalHistogram: Sendable, Equatable {
    /// `counts[k]` is how many observed intervals saw exactly `k` jobs arrive.
    public let counts: [Int]

    public init(counts: [Int]) {
        // Negative observation counts are meaningless; clamp rather than trust.
        self.counts = counts.map { max(0, $0) }
    }

    /// Convenience: build a histogram from a raw list of per-interval arrivals.
    public init(observations: [Int]) {
        let clamped = observations.map { max(0, $0) }
        let highest = clamped.max() ?? 0
        // Guard the allocation: a single corrupt observation must not ask for a
        // billion-element array.
        let cap = min(highest, ArrivalHistogram.maxTrackedArrivals)
        var buckets = [Int](repeating: 0, count: Saturating.add(cap, 1))
        for value in clamped {
            let index = min(value, cap)
            // `index` is in 0...cap and `buckets` has cap + 1 elements.
            if buckets.indices.contains(index) {
                buckets[index] = Saturating.add(buckets[index], 1)
            }
        }
        self.counts = buckets
    }

    /// Ceiling on histogram width. Derived from nothing clever — it is simply
    /// larger than any real fleet and small enough to allocate safely.
    public static let maxTrackedArrivals = 4096

    public var totalIntervals: Int { Saturating.sum(counts) }

    public var isEmpty: Bool { totalIntervals == 0 }

    /// Highest arrival count ever observed.
    public var maxObserved: Int {
        guard let last = counts.lastIndex(where: { $0 > 0 }) else { return 0 }
        return last
    }

    /// Jobs that would find no warm host at `depth`, summed over all intervals.
    ///
    /// This is the quantity the cost function is actually about: not "how often
    /// do we miss" but "how many runs pay a cold start", which is the integral
    /// of the overflow above the pool depth.
    public func expectedColdStarts(atDepth depth: Int) -> Int {
        guard depth >= 0 else { return expectedColdStarts(atDepth: 0) }
        var total = 0
        for (arrivals, intervals) in counts.enumerated() where arrivals > depth {
            let overflow = Saturating.subtract(arrivals, depth)
            total = Saturating.add(total, Saturating.multiply(overflow, intervals))
        }
        return total
    }
}

/// What a warm host costs to keep and what a cold start costs to pay.
///
/// Both in the same arbitrary integer unit — cents, credits, engineer-seconds —
/// because the sizer only ever compares them to each other, and keeping the unit
/// abstract stops anyone from reading a currency into the output that the inputs
/// did not put there.
public struct PoolCostModel: Sendable, Equatable {
    /// Cost of holding one host warm for one observation interval.
    public let idleHostCostPerInterval: Int
    /// Cost of one job paying a full restore instead of landing warm.
    public let coldStartCostPerJob: Int

    public init(idleHostCostPerInterval: Int, coldStartCostPerJob: Int) {
        self.idleHostCostPerInterval = max(0, idleHostCostPerInterval)
        self.coldStartCostPerJob = max(0, coldStartCostPerJob)
    }
}

/// One point on the cost curve.
public struct PoolCostPoint: Sendable, Equatable {
    public let depth: Int
    public let idleCost: Int
    public let coldStartCost: Int
    public var totalCost: Int { Saturating.add(idleCost, coldStartCost) }
}

public struct PoolSizingResult: Sendable, Equatable {
    /// The depth minimising total cost.
    public let recommendedDepth: Int
    /// Every evaluated depth, ascending. Shown rather than summarised, because
    /// a lead choosing a pool depth needs to see how flat the minimum is — a
    /// curve that is flat from 6 to 11 is a different decision from one with a
    /// sharp notch at 8.
    public let curve: [PoolCostPoint]

    public var minimumCost: Int {
        curve.first(where: { $0.depth == recommendedDepth })?.totalCost ?? 0
    }
}

public enum PoolSizer {

    /// Evaluates the real cost at every depth in `0...maxDepth` and returns the
    /// cheapest.
    ///
    /// Ties resolve to the *smaller* depth: two depths that cost the same are
    /// not equivalent, because the smaller one holds fewer hosts hostage and
    /// leaves more headroom for the next capacity decision.
    public static func size(
        histogram: ArrivalHistogram,
        model: PoolCostModel,
        maxDepth: Int? = nil
    ) -> PoolSizingResult {
        let intervals = histogram.totalIntervals
        guard intervals > 0 else {
            return PoolSizingResult(
                recommendedDepth: 0,
                curve: [PoolCostPoint(depth: 0, idleCost: 0, coldStartCost: 0)]
            )
        }

        // Past the largest burst ever observed, extra depth buys nothing and
        // only adds idle cost, so there is no reason to evaluate further.
        let ceiling = Saturating.clamp(
            maxDepth ?? histogram.maxObserved,
            to: 0...ArrivalHistogram.maxTrackedArrivals
        )

        var curve: [PoolCostPoint] = []
        curve.reserveCapacity(Saturating.add(ceiling, 1))

        var bestDepth = 0
        var bestCost = Int.max

        for depth in 0...ceiling {
            let idle = Saturating.multiply(
                Saturating.multiply(depth, model.idleHostCostPerInterval),
                intervals
            )
            let cold = Saturating.multiply(
                histogram.expectedColdStarts(atDepth: depth),
                model.coldStartCostPerJob
            )
            let point = PoolCostPoint(depth: depth, idleCost: idle, coldStartCost: cold)
            curve.append(point)

            // Strict `<` implements the documented tie-break toward smaller depth.
            if point.totalCost < bestCost {
                bestCost = point.totalCost
                bestDepth = depth
            }
        }

        return PoolSizingResult(recommendedDepth: bestDepth, curve: curve)
    }
}
