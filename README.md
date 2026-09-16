# DeviceFarmScheduler

**A capacity-and-scheduling layer for a fleet of virtualized iPhones — the part nobody built.**

Last Friday `vphone-cli` started booting unmodified iOS 27 firmware on Apple Silicon through
`Virtualization.framework`, with a real boot chain, DFU restore, and root SSH. Overnight,
"iOS device farm" stopped being a procurement problem and became a scheduling problem.

Scheduling problems have wrong answers that look right. This package implements three of them
next to the one this repo argues for, runs all four over the same recorded workload, and lets
the numbers decide.

> **The finding that matters:** the obvious implementation of "be fair, but exploit the cache"
> lands a **38%** warm hit rate — thirteen points above pure round-robin, and 45 points below
> what the cache can actually give you. Fairness and affinity do not compose by layering. They
> compose by layering *plus a bounded delay*, which takes the same workload to **62%**.

---

## Why this matters

A coding agent can already write the Swift. What it has never had is somewhere to *run* it. The
bottleneck in an agent-assisted iOS team is not generation, it is verification — and verification
needs devices, which are the one resource that does not scale with spend. A farm is the substrate
that turns an agent's diff into a tested artifact, and the farm's throughput is set almost
entirely by one number: how often a run finds its snapshot already on the host it lands on.

Which makes two independently reasonable decisions load-bearing, and both of them are usually
made wrong:

| Decision | The reflex | What it costs |
|---|---|---|
| How the snapshot store evicts | LRU | Evicts the shared base image first — the most expensive layer in the store |
| How the scheduler places work | fair-share, or affinity | One starves a tenant; the other wastes the cache |

---

## Three findings, all measured

Everything below comes from the test suite. The fixture is a single named workload,
`ReferenceWorkload`, fixed before any policy was written — 8 hosts, 2 OS builds, 3 tenants at
60/30/10 of arrivals, 251 runs arriving in bursts of 2–6 across a 30-minute window.

### 1. LRU evicts exactly the layer you cannot afford to lose

A snapshot is not one blob. It is a copy-on-write chain: restored firmware (6 GiB, ~3 min),
the app image written on top of it (~900 MiB, ~25 s), the seeded account state on top of that
(~200 MiB, ~6 s). A run mounts the `.account` leaf, so that is the layer a naive store stamps
with a timestamp. The base image underneath is never mounted directly by anything — so its
"last used" time never moves, and global LRU evicts it first.

That single eviction orphans every descendant. The layers stay resident and stop being bootable.

Over 36 mounts against a store under pressure (`SnapshotStoreTests`):

| | Restore time paid | Steps holding unbootable layers |
|---|---|---|
| Global LRU | **829 s** | 33 of 36 |
| Chain-aware (this package) | **640 s** | 0 of 36 |

29% more restore time, and a store whose *reported* capacity and *usable* capacity had drifted
apart. `SnapshotStore` fixes both halves: only leaves are evictable, so the resident set is
always a valid forest; and candidates are ranked by rebuild time saved per byte held rather
than by age.

### 2. Neither obvious placement policy is acceptable, and layering them is not enough

| Policy | Runs started | Warm hit rate | Restore paid | Worst wait | Who waited longest |
|---|---|---|---|---|---|
| Affinity-first | 248 | **83%** | 49 min | 659 s | **`payments`** (the smallest tenant) |
| Strict fairness | 140 | 25% | 139 min | 1080 s | `checkout` |
| Naive layering (DRR + affinity) | 142 | 38% | 137 min | 1080 s | `checkout` |
| **DRR + delay scheduling** | 240 | **62%** | **48 min** | **348 s** | `checkout` |

Affinity-first maximises the cache by construction and hands the farm to whoever already had it:
warmth is a proxy for "ran recently", so the small tenant's chain is never resident, so it never
wins a comparison. It is the only policy here under which **the smallest tenant is the
worst-served one** — and that is asserted as a test, not as an opinion.

Strict fairness rotates hosts, so every host ends up holding a little of everything and the
fleet spends 139 minutes rewriting base images it already had.

**Naive layering — DRR to pick the tenant, affinity to pick the job and host — barely helps.**
That result is the reason this package exists in the shape it does. The inner loop only chooses
among *one* tenant's jobs, while the expensive decision — whether to rewrite a host's 6 GiB base
image — is forced by *which tenant's turn it is*. Round-robin across tenants on different OS
builds makes hosts ping-pong, and no cleverness inside a single turn undoes that.

The fix is delay scheduling (Zaharia et al., Hadoop Fair Scheduler): a tenant whose turn has come
but whose only available host would need an OS flip **passes, keeps its credit, and waits** — at
most `maxSkips` times, after which it is served cold regardless. The farm trades a few seconds of
idle host time against a three-minute restore, and the fleet self-organises: hosts settle onto OS
builds instead of thrashing between them.

Setting `maxSkips: 0` reduces the policy to the naive layering in row three, and a test asserts
the hit rate collapses when you do. The delay-scheduling component is load-bearing by
measurement.

**The honest other half:** affinity-first still wins the hit-rate column, 83% to 62%. Fairness is
not free, and there is a test named `testAffinityFirstStillWinsTheHitRateColumn` whose only job is
to fail if this README ever starts claiming otherwise. What the layered policy buys for those 21
points is a worst-case wait cut from 659 s to 348 s, and a small tenant that is no longer last in
every queue.

**And the part worth staring at:** the layered policy takes *more than twice as many cache misses*
as affinity-first — 91 against 42 — while paying **less** total restore time, 48 minutes against
49. Its average miss costs 32 s; affinity-first's costs 70 s. That is the whole mechanism in one
pair of numbers. Delay scheduling does not chase a higher hit rate; it changes which misses you
take, trading a handful of cheap app-layer restores for the base-image rewrites that actually hurt.
A hit-rate column alone would have called this policy the loser.

### 3. Don't fit a distribution to a workload whose defining feature is correlated bursts

PR traffic is not Poisson. It correlates with the workday, the release train, and — increasingly
the dominant term — with agent fan-out, where one human action enqueues twenty runs at once.
Fitting a distribution whose defining assumption is independence produces a confident number
that is wrong in exactly the tail you are sizing for.

`PoolSizer` fits nothing. It takes the observed arrival histogram and evaluates the real cost at
every candidate depth. On the reference workload's 60 observation windows (arrivals 2–6) it
returns depth 6 **and the whole curve**, because a lead choosing a pool depth needs to see
whether the minimum is a sharp notch or a flat plateau.

One decision inside it is worth naming: the observation window is explicit, not implicit. Bucket
per second and the question becomes "how many jobs arrived this second", answered "zero" in 97%
of buckets, from which the sizer correctly concludes no warm pool is ever worth its idle cost —
right about the model, wrong about the farm.

---

## What's in it

| Type | Responsibility |
|---|---|
| `SnapshotKey` / `LayerID` / `SnapshotLayer` | The copy-on-write chain, and the sharing that makes eviction a forest problem |
| `SnapshotStore` | One host's resident set; leaf-first, value-ranked eviction that cannot orphan |
| `SnapshotStoreAudit` | Standalone invariant checker — takes a resident set from *any* implementation |
| `LayeredAffinityFairPolicy` | DRR outer loop, affinity inner loop, bounded delay scheduling |
| `AffinityFirstPolicy` / `StrictFairnessPolicy` | The two baselines, shipped as real measurable policies |
| `SchedulerState` | Queues, deficits, hosts — a synchronous, replayable value type |
| `AdmissionController` | What the farm refuses, and the wait it states instead of hiding |
| `PoolSizer` / `ArrivalHistogram` | Warm-pool depth from observed arrivals, with the full cost curve |
| `LeaseManager` / `RunLedger` | Heartbeat leases, fencing tokens, exactly-once result capture |
| `LedgerAudit` | Standalone exactly-once checker, for auditing traces the ledger did not produce |
| `FarmCoordinator` | The actor boundary — and the reason there is no `await` inside it |
| `FarmSimulation` / `ReferenceWorkload` | The deterministic fixture every number above comes from |

---

## Design decisions, and what was rejected

**The scheduler core is synchronous value types, not actors.** "Why did job 4412 wait nine
minutes" is a question somebody will ask, and a deterministic state machine can be replayed from
a recorded arrival trace to answer it exactly. Concurrency lives at the edge. `FarmCoordinator`
is an actor, and no method on it contains an `await` — there is no suspension point between
reading state and writing it, so the classic reentrancy hazard (a placement computed against six
idle hosts, applied after two were taken) is impossible by construction rather than by
convention. That is a property you can check with `grep`.

**Rejected: first-write-wins in the ledger.** It sounds safer. It lets a zombie that briefly
outruns the reclaim sweep pin a stale verdict the legitimate current holder can never correct.
Since only the current lease holder can hold the highest fencing token, highest-token-wins is
the rule that makes the current owner authoritative. A reclaimed host can never report green —
not because its result looks wrong, but because nothing about a zombie's result *could* look
wrong, so the check has to be on the token.

**A retried run keeps its run id.** Allocating a fresh one on retry is the obvious
implementation and it quietly defeats the fencing token: the zombie's write is then merely
irrelevant rather than rejected, and the CI job waiting on that run gets two verdicts.

**The deficit ceiling stretches to the largest waiting job.** Classic DRR requires the quantum to
be at least the maximum packet size. A farm cannot promise that — the largest job is a property
of somebody else's test suite. A fixed `quantum × multiplier` ceiling means a run costing more
than the ceiling is skipped on every round forever, while the queue reports it as merely
"waiting". That was a real bug here, found by a test, fixed by making the ceiling adapt.

**Rejected: Poisson arrivals.** See finding 3.

**Every trapping operation is guarded.** `Int(Double)` traps on NaN, infinity and out-of-range;
`/` and `%` trap on zero and on `Int.min / -1`; `+` and `*` trap on overflow. A scheduler ingests
numbers it does not control — byte counts from a hypervisor, cost weights from a dashboard — and
a scheduler that crashes is worse than one that mis-sizes a pool. `Saturating` centralises this,
derives ceilings from `Int.max` rather than a 64-bit literal, and has tests that pin the exact
saturated value for every trapping input rather than asserting "doesn't crash".

---

## Verification

**97 XCTest cases, 0 failures.** Clean build (`rm -rf .build`) with
`swift build -Xswiftc -warnings-as-errors`: 0 warnings, 0 errors, Swift 6 language mode.

CI runs on every push — see the repo's **Actions** tab. Three checks: a grep that fails the build
if any `await` appears in `Sources/` (see below); Linux building and testing the whole package
with warnings-as-errors, so the zero-warning claim is machine-enforced rather than asserted here;
and macOS doing the same plus compiling the SwiftUI module for
`generic/platform=iOS Simulator`, which the Linux job cannot reach.

**Every number in this README is a test.** `GoldenNumbersTests` pins all of them — each policy's
runs started, hit rate, restore minutes, worst wait and worst-served tenant, the arrival
histogram, the full sizing curve, both figures in the store differential, and the six-host
numbers the demo app's README quotes. The rest of the suite asserts orderings, which is the right
shape for the arguments but would let the *figures* drift while CI stayed green. Change the
scheduler and this file fails until the prose is updated in the same commit.

**Not verified: nothing here has been run on a Simulator, and no screenshots exist anywhere in
either repository.** This was built by an unattended scheduled task; Simulator access was
requested three times and refused each time with *"Computer-use access to 'Simulator' can't be
approved during a scheduled run."* The companion demo app's CI compiles it for an iOS Simulator
destination — that is a strictly weaker claim than having launched it, and the two are kept
separate here deliberately.

**The tests are built so they can fail.** A checker that can only be pointed at the implementation
it is checking proves nothing, so:

- `NaiveLRUStore` is a complete, working global-LRU store, and the differential test asserts it
  *does* orphan a layer — if it ever stops, the comparison is declared worthless in the failure
  message.
- `PermissiveLedger` accepts every write, and `LedgerAudit` is asserted to catch it.
- `SnapshotStoreAudit` is fed a hand-built orphaned resident set and asserted to report it.
- `LayeredAffinityFairPolicy(maxSkips: 0)` is a deliberately degraded version of the shipped
  policy, and its hit rate is asserted to collapse toward the strict-fairness baseline.
- `testAffinityFirstStillWinsTheHitRateColumn` fails if this README's honesty about the trade-off
  ever stops being true.

Known limits, stated — and, where they are checkable, checked:

- The store differential is a **pressure-regime** result. Give the store enough room and both
  policies pay identically; at one capacity in the sweep the chain-aware store is *worse*.
  `testStoreAdvantageIsCapacityDependentAsDocumented` asserts all three regimes, so this caveat
  fails the build if it ever stops being true — an admission nobody verifies is just modesty.
- `maxSkips: 24` is the shipped default because a sweep says so, and the sweep ships as
  `testSkipBoundSweepShapeIsStable`. It is not a universal constant: it is the knee for *this*
  workload, and the test pins the shape rather than the value's optimality in general.
- Everything here is measured against one fixture on a simulated fleet. No VM has ever booted.
  The arithmetic is real; the farm is not.

---

## Usage

```swift
.package(url: "https://github.com/rajatslakhina/device-farm-scheduler-kit.git", from: "1.0.0")
```

```swift
import DeviceFarmScheduler

let coordinator = FarmCoordinator(
    state: ReferenceWorkload.makeSpec().makeState(),
    policy: LayeredAffinityFairPolicy(),          // maxSkips: 24 by default
    admission: AdmissionController(policy: ReferenceWorkload.makeAdmissionPolicy()),
    leaseTTLTicks: 30
)

switch await coordinator.submit(job) {
case .admit(let wait):                     print("starts in ~\(wait)s")
case .admitOverBudget(let wait, let cap):  print("over budget: ~\(wait)s vs \(cap)s")
case .rejectQueueFull, .rejectTenantQuota, .rejectUnknownSnapshot:
    break                                  // refused fast, which is the point
}
```

Compare policies on your own workload:

```swift
for report in FarmSimulation.compareShippedPolicies(spec: mySpec) {
    print(report.policyName, report.warmHitRatePercent, report.worstTenantWaitTicks)
}
```

`DeviceFarmSchedulerUI` ships `FarmConsoleView`, which renders that comparison and takes its
workload as a parameter rather than hardcoding one.

## Demo app

A SwiftUI console that renders this comparison lives in its own repository and consumes this
package as a remote Swift package dependency, constrained to the `1.x` line:
**[device-farm-scheduler-demo-app](https://github.com/rajatslakhina/device-farm-scheduler-demo-app)**

It runs the same workload on a deliberately tighter **six**-host fleet, where the contention makes
the difference stark: affinity-first posts a **91%** warm hit rate while running the smallest
tenant's suite **twice** in thirty minutes. Those six-host figures are pinned by
`testDemoAppSixHostNumbersArePinned` in this repository, because the demo has no test target of
its own to pin them in.

## Requirements

iOS 17+ / macOS 14+ · Swift 6.0+ · no third-party dependencies

## Attribution

Delay scheduling is from Zaharia et al., *Delay Scheduling: A Simple Technique for Achieving
Locality and Fairness in Cluster Scheduling* (EuroSys 2010). Fencing tokens are the standard
pattern from Kleppmann's 2016 distributed-locking argument. Neither is claimed as novel; the
contribution here is the measurement of what happens on an iOS device farm when you leave them
out.

## License

MIT
