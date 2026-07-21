import Foundation

public enum WorkoutChargePolicy {
    public static let maximumStrain = 21.0
    public static let maximumAward = 50

    /// Maps WHOOP's personalized nonlinear Workout Strain onto a second smooth
    /// curve. Every valid scored workout earns at least one Charge.
    public static func award(for strain: Double) -> Int? {
        guard strain.isFinite, (0...maximumStrain).contains(strain) else {
            return nil
        }
        let normalized = strain / maximumStrain
        let curved = Double(maximumAward) * normalized * normalized
        return max(1, min(maximumAward, Int(curved.rounded())))
    }
}
