import Foundation

/// Structure over the decayed app→app counts: which pairs travel together
/// far beyond chance, and which groups form a working set. The evidence
/// base for breath recommendations — a cluster that keeps co-occurring is
/// a layout waiting for a name.
public enum Transitions {
    public struct Pair: Equatable {
        public let from: String
        public let to: String
        public let count: Double
        /// Observed ÷ expected under independence. 1 is chance; 3 is a
        /// habit of moving between exactly these two.
        public let lift: Double
    }

    public struct Cluster: Equatable {
        public let apps: [String]
        /// Total internal transition weight.
        public let weight: Double
    }

    static func totals(_ matrix: [String: [String: Double]])
        -> (total: Double, outbound: [String: Double], inbound: [String: Double]) {
        var outbound: [String: Double] = [:]
        var inbound: [String: Double] = [:]
        var total = 0.0
        for (from, row) in matrix {
            for (to, count) in row {
                outbound[from, default: 0] += count
                inbound[to, default: 0] += count
                total += count
            }
        }
        return (total, outbound, inbound)
    }

    /// Pairs ordered by evidence: enough mass to matter, lift to prove it
    /// is not two popular apps colliding by chance.
    public static func strongPairs(_ matrix: [String: [String: Double]],
                                   minimumCount: Double = 4) -> [Pair] {
        let (total, outbound, inbound) = totals(matrix)
        guard total > 0 else { return [] }
        var pairs: [Pair] = []
        for (from, row) in matrix {
            for (to, count) in row where count >= minimumCount {
                let expected = (outbound[from] ?? 0) * (inbound[to] ?? 0) / total
                guard expected > 0 else { continue }
                pairs.append(Pair(from: from, to: to, count: count, lift: count / expected))
            }
        }
        return pairs.sorted { $0.count * $0.lift > $1.count * $1.lift }
    }

    /// Where attention lives at equilibrium: the stationary distribution
    /// of the transition chain, by power iteration.
    public static func stationary(_ matrix: [String: [String: Double]],
                                  iterations: Int = 60) -> [String: Double] {
        let apps = Array(Set(matrix.keys).union(matrix.values.flatMap(\.keys))).sorted()
        guard !apps.isEmpty else { return [:] }
        let index = Dictionary(uniqueKeysWithValues: apps.enumerated().map { ($1, $0) })
        let n = apps.count
        var rows = Array(repeating: Array(repeating: 1.0 / Double(n), count: n), count: n)
        for (from, row) in matrix {
            guard let i = index[from] else { continue }
            let mass = row.values.reduce(0, +)
            guard mass > 0 else { continue }
            for j in 0..<n { rows[i][j] = 0 }
            for (to, count) in row {
                guard let j = index[to] else { continue }
                rows[i][j] = count / mass
            }
        }
        var p = Array(repeating: 1.0 / Double(n), count: n)
        for _ in 0..<iterations {
            var next = Array(repeating: 0.0, count: n)
            for i in 0..<n {
                for j in 0..<n { next[j] += p[i] * rows[i][j] }
            }
            // A pinch of teleport keeps a reducible chain from trapping mass.
            let teleport = 0.05 / Double(n)
            for j in 0..<n { next[j] = next[j] * 0.95 + teleport }
            p = next
        }
        return Dictionary(uniqueKeysWithValues: zip(apps, p))
    }

    /// Greedy agglomerative clustering on the symmetrized graph, with the
    /// configuration model as the null: two clusters merge only when the
    /// weight between them beats what their sheer sizes predict, by a
    /// margin. An absolute threshold saturated at real event volume and
    /// produced one cluster of everything — on an attention graph every
    /// app touches the busy core, so "connected at all" is no structure.
    /// "Connected half again past expectation" is.
    public static func clusters(_ matrix: [String: [String: Double]],
                                minimumWeight: Double = 6,
                                liftFloor: Double = 1.5) -> [Cluster] {
        var weight: [String: [String: Double]] = [:]
        var degree: [String: Double] = [:]
        for (from, row) in matrix {
            for (to, count) in row where from != to {
                weight[from, default: [:]][to, default: 0] += count
                weight[to, default: [:]][from, default: 0] += count
                degree[from, default: 0] += count
                degree[to, default: 0] += count
            }
        }
        let twoM = degree.values.reduce(0, +)
        guard twoM > 0 else { return [] }
        var clusters: [[String]] = Array(Set(matrix.keys).union(matrix.values.flatMap(\.keys)))
            .sorted().map { [$0] }

        func between(_ a: [String], _ b: [String]) -> Double {
            a.reduce(0) { sum, app in
                sum + b.reduce(0) { $0 + (weight[app]?[$1] ?? 0) }
            }
        }
        func clusterDegree(_ members: [String]) -> Double {
            members.reduce(0) { $0 + (degree[$1] ?? 0) }
        }

        while clusters.count > 1 {
            var best: (i: Int, j: Int, ratio: Double)?
            for i in 0..<clusters.count {
                for j in (i + 1)..<clusters.count {
                    let cross = between(clusters[i], clusters[j])
                    guard cross >= minimumWeight else { continue }
                    let expected = clusterDegree(clusters[i]) * clusterDegree(clusters[j])
                        / twoM
                    guard expected > 0 else { continue }
                    let ratio = cross / expected
                    if ratio >= liftFloor, ratio > (best?.ratio ?? 0) {
                        best = (i, j, ratio)
                    }
                }
            }
            guard let merge = best else { break }
            let absorbed = clusters.remove(at: merge.j)
            clusters[merge.i].append(contentsOf: absorbed)
        }
        return clusters.filter { $0.count > 1 }.map { members in
            Cluster(apps: members.sorted(),
                    weight: between(members, members) / 2)
        }.sorted { $0.weight > $1.weight }
    }
}
