import Foundation

/// The records' upkeep (the monthly archive rolled, each log's ring
/// rotated) waits for an instance that has settled and is staying. Upkeep
/// is a full decode and rewrite on queues the quit save also uses, and an
/// update's relay is replaced by launchd's instance a moment after it
/// boots: started at launch, it held every update's handover for the full
/// five seconds the successor waits. Work that can wait is never on the
/// launch path.
enum BootUpkeep {
    static let settleSeconds: TimeInterval = 60

    static func schedule(after seconds: TimeInterval = settleSeconds,
                         isResident: @escaping () -> Bool,
                         tend: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            guard isResident() else { return }
            tend()
        }
    }
}
