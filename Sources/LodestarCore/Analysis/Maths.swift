import Foundation

/// The numerical floor the models stand on. Small, closed-form, dependency
/// free — everything here fits in a screen and is exact enough for data
/// measured in hundreds of samples.
public enum Maths {
    public static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    public static func variance(_ values: [Double]) -> Double? {
        guard values.count > 1, let m = mean(values) else { return nil }
        let ss = values.reduce(0) { $0 + ($1 - m) * ($1 - m) }
        return ss / Double(values.count - 1)
    }

    public static func median(_ values: [Double]) -> Double? {
        Observations.median(values)
    }

    /// Standard normal CDF via the erf the C library already ships.
    public static func normalCDF(_ z: Double) -> Double {
        0.5 * (1 + erf(z / 2.0.squareRoot()))
    }

    /// Ordinary least squares by normal equations with Gaussian
    /// elimination. Fine at the sizes used here (a handful of predictors);
    /// returns nil when the system is singular, which callers must treat
    /// as "not enough variation to say".
    public static func ols(rows: [[Double]], y: [Double]) -> [Double]? {
        guard !rows.isEmpty, rows.count == y.count, let k = rows.first?.count, k > 0,
              rows.allSatisfy({ $0.count == k }), rows.count > k else { return nil }
        // XtX and Xty.
        var xtx = Array(repeating: Array(repeating: 0.0, count: k), count: k)
        var xty = Array(repeating: 0.0, count: k)
        for (row, target) in zip(rows, y) {
            for i in 0..<k {
                xty[i] += row[i] * target
                for j in i..<k { xtx[i][j] += row[i] * row[j] }
            }
        }
        for i in 0..<k { for j in 0..<i { xtx[i][j] = xtx[j][i] } }
        return solve(xtx, xty)
    }

    /// Ridge regression: OLS with a small penalty on the coefficients, so
    /// a collinear or degenerate design — a graph whose chains all share
    /// one digraph shape, which real configs produce constantly — still
    /// yields well-defined *predictions*. The penalty is tiny; it exists
    /// to break ties, not to shrink anything that has data behind it.
    public static func ridge(rows: [[Double]], y: [Double], lambda: Double = 0.01)
        -> [Double]? {
        guard !rows.isEmpty, rows.count == y.count, let k = rows.first?.count, k > 0,
              rows.allSatisfy({ $0.count == k }) else { return nil }
        var xtx = Array(repeating: Array(repeating: 0.0, count: k), count: k)
        var xty = Array(repeating: 0.0, count: k)
        for (row, target) in zip(rows, y) {
            for i in 0..<k {
                xty[i] += row[i] * target
                for j in i..<k { xtx[i][j] += row[i] * row[j] }
            }
        }
        for i in 0..<k {
            for j in 0..<i { xtx[i][j] = xtx[j][i] }
            xtx[i][i] += lambda
        }
        return solve(xtx, xty)
    }

    /// Exact binomial upper tail: P(X ≥ k | n, p), in log space so a few
    /// hundred trials cannot overflow. The honest p-value for "this letter
    /// keeps being the wrong one" and "this host keeps landing there".
    public static func binomialTail(atLeast k: Int, n: Int, p: Double) -> Double {
        guard n > 0, k <= n, p > 0, p < 1 else { return k <= 0 ? 1 : (p >= 1 ? 1 : 0) }
        guard k > 0 else { return 1 }
        var total = 0.0
        for i in k...n {
            let logTerm = lgamma(Double(n + 1)) - lgamma(Double(i + 1))
                - lgamma(Double(n - i + 1))
                + Double(i) * log(p) + Double(n - i) * log(1 - p)
            total += exp(logTerm)
        }
        return min(1, total)
    }

    /// Gaussian elimination with partial pivoting.
    static func solve(_ matrix: [[Double]], _ rhs: [Double]) -> [Double]? {
        let n = rhs.count
        var a = matrix
        var b = rhs
        for column in 0..<n {
            var pivot = column
            for row in (column + 1)..<n where abs(a[row][column]) > abs(a[pivot][column]) {
                pivot = row
            }
            guard abs(a[pivot][column]) > 1e-10 else { return nil }
            if pivot != column {
                a.swapAt(pivot, column)
                b.swapAt(pivot, column)
            }
            for row in (column + 1)..<n {
                let factor = a[row][column] / a[column][column]
                guard factor != 0 else { continue }
                for j in column..<n { a[row][j] -= factor * a[column][j] }
                b[row] -= factor * b[column]
            }
        }
        var x = Array(repeating: 0.0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var value = b[row]
            for j in (row + 1)..<n { value -= a[row][j] * x[j] }
            x[row] = value / a[row][row]
        }
        return x
    }

    /// Benjamini–Hochberg: which hypotheses survive at false-discovery
    /// rate `q`. Input is p-values; output is the indices that pass. The
    /// report's credibility rests on never crying wolf, and this is the
    /// arithmetic of not crying wolf across many simultaneous tests.
    public static func benjaminiHochberg(_ pValues: [Double], q: Double = 0.1) -> Set<Int> {
        guard !pValues.isEmpty else { return [] }
        let sorted = pValues.enumerated().sorted { $0.element < $1.element }
        let m = Double(pValues.count)
        var cutoff = -1
        for (rank, entry) in sorted.enumerated()
            where entry.element <= Double(rank + 1) / m * q {
            cutoff = rank
        }
        guard cutoff >= 0 else { return [] }
        return Set(sorted.prefix(cutoff + 1).map(\.offset))
    }

    /// Empirical-Bayes shrinkage: pull each group mean toward the grand
    /// mean by how little data it has. `tau2` is the between-group
    /// variance estimated by method of moments; a group with plenty of
    /// samples keeps its own mean, a thin one borrows the population's.
    public static func shrink(groupMeans: [(mean: Double, n: Int)], withinVariance: Double)
        -> [Double] {
        let means = groupMeans.map(\.mean)
        guard let grand = mean(means) else { return [] }
        let observed = variance(means) ?? 0
        let averageNoise = mean(groupMeans.map { withinVariance / Double(max(1, $0.n)) }) ?? 0
        let tau2 = max(0, observed - averageNoise)
        return groupMeans.map { group in
            let noise = withinVariance / Double(max(1, group.n))
            let weight = tau2 + noise > 0 ? tau2 / (tau2 + noise) : 0
            return weight * group.mean + (1 - weight) * grand
        }
    }

    /// Wilson score lower bound for a binomial proportion — the honest
    /// "at least this often" from a small count.
    public static func wilsonLower(successes: Int, trials: Int, z: Double = 1.96) -> Double {
        guard trials > 0 else { return 0 }
        let n = Double(trials)
        let p = Double(successes) / n
        let z2 = z * z
        let denominator = 1 + z2 / n
        let center = p + z2 / (2 * n)
        let margin = z * ((p * (1 - p) + z2 / (4 * n)) / n).squareRoot()
        return max(0, (center - margin) / denominator)
    }
}
