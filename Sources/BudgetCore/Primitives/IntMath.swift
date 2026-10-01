/// Integer helpers. Swift's `/` and `%` truncate toward zero, which is wrong for
/// date arithmetic before an anchor, so these use floor semantics.
public enum IntMath {
    /// ⌊a / b⌋ for b > 0.
    @inlinable
    public static func floorDiv(_ a: Int, _ b: Int) -> Int {
        precondition(b > 0, "floorDiv divisor must be positive")
        let q = a / b
        return (a % b != 0 && a < 0) ? q - 1 : q
    }

    /// ⌈a / b⌉ for b > 0.
    @inlinable
    public static func ceilDiv(_ a: Int, _ b: Int) -> Int {
        -floorDiv(-a, b)
    }

    /// a mod b in 0..<b for b > 0.
    @inlinable
    public static func floorMod(_ a: Int, _ b: Int) -> Int {
        a - floorDiv(a, b) * b
    }

    /// num / den rounded to the nearest integer, halves away from zero. den > 0.
    @inlinable
    public static func roundedDiv(_ num: Int64, _ den: Int64) -> Int64 {
        precondition(den > 0, "roundedDiv divisor must be positive")
        if num >= 0 {
            return (num + den / 2) / den
        }
        return -((-num + den / 2) / den)
    }

    /// ⌊num / den⌋ for den > 0.
    @inlinable
    public static func floorDiv64(_ num: Int64, _ den: Int64) -> Int64 {
        precondition(den > 0, "floorDiv64 divisor must be positive")
        let q = num / den
        return (num % den != 0 && num < 0) ? q - 1 : q
    }
}
