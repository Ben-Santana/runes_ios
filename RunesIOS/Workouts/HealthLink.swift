import Foundation
import HealthKit

/// The only place Runes talks to Apple Health. It adds finished workouts and can remove the
/// ones it added. It asks to write workouts, and heart rate once a wearable is linked, and
/// it reads nothing.
final class HealthLink: @unchecked Sendable {
    /// False on a device without Health.
    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }
    /// Opens the Health app, where the person changes what Runes may do.
    static let appURL = URL(string: "x-apple-health://")!

    private let store: HKHealthStore? = HealthLink.isAvailable ? HKHealthStore() : nil

    var access: HealthAccess {
        guard let store else { return .unavailable }
        switch store.authorizationStatus(for: HKObjectType.workoutType()) {
        case .sharingAuthorized: return .allowed
        case .sharingDenied: return .denied
        default: return .notAsked
        }
    }

    /// Shows Health's permission sheet the first time, and once more when heart rate is first
    /// asked for. After that it answers at once.
    func requestAccess(heart: Bool) async -> HealthAccess {
        guard let store else { return .unavailable }
        let types: Set<HKSampleType> = heart ? [HKObjectType.workoutType(), Self.heartRate] : [HKObjectType.workoutType()]
        try? await store.requestAuthorization(toShare: types, read: [])
        return access
    }

    /// Adds the workout and returns Health's identifier for it.
    func save(_ workout: HealthWorkout) async throws -> String {
        guard let store else { throw HKError(.errorHealthDataUnavailable) }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = workout.activity.type
        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: nil)
        try await builder.beginCollection(at: workout.start)
        do {
            // Heart rate is extra: a workout is still saved when Health will not take it.
            if !workout.heart.isEmpty, store.authorizationStatus(for: Self.heartRate) == .sharingAuthorized {
                try? await builder.addSamples(Self.samples(workout))
            }
            try await builder.addMetadata(Self.metadata(workout))
            try await builder.addWorkoutEvents(workout.sets.map { Self.event($0, unit: workout.unit) })
            try await builder.endCollection(at: workout.end)
            guard let saved = try await builder.finishWorkout() else { throw HKError(.errorHealthDataUnavailable) }
            return saved.uuid.uuidString
        } catch {
            builder.discardWorkout()
            throw error
        }
    }

    /// Removes workouts Runes added. Health refuses anything another app wrote.
    func remove(_ identifiers: [String]) async {
        let uuids = Set(identifiers.compactMap(UUID.init))
        guard let store, !uuids.isEmpty else { return }
        _ = try? await store.deleteObjects(of: HKObjectType.workoutType(), predicate: HKQuery.predicateForObjects(with: uuids))
    }

    private static let heartRate = HKQuantityType(.heartRate)

    /// The wearable's readings as Health samples, named as coming from the wearable.
    private static func samples(_ workout: HealthWorkout) -> [HKQuantitySample] {
        let device = workout.heartSource.map {
            HKDevice(name: $0, manufacturer: nil, model: nil, hardwareVersion: nil, firmwareVersion: nil, softwareVersion: nil,
                     localIdentifier: nil, udiDeviceIdentifier: nil)
        }
        let unit = HKUnit.count().unitDivided(by: .minute())
        return workout.heart.map {
            HKQuantitySample(type: heartRate, quantity: HKQuantity(unit: unit, doubleValue: Double($0.beats)), start: $0.at, end: $0.at,
                             device: device, metadata: nil)
        }
    }

    // Health has no fields of its own for sets and reps, so they travel as the workout's
    // events and under Runes' own keys. Other apps may ignore them.

    private static func metadata(_ workout: HealthWorkout) -> [String: Any] {
        var values: [String: Any] = [HKMetadataKeyExternalUUID: workout.id, "RunesWorkout": workout.name,
                                     "RunesSets": workout.sets.count, "RunesReps": workout.totalReps]
        if workout.volume > 0 { values["RunesVolume"] = HKQuantity(unit: workout.unit.mass, doubleValue: workout.volume) }
        return values
    }

    /// A set as a segment of the workout from its start to its stop.
    private static func event(_ set: HealthSet, unit: WeightUnit) -> HKWorkoutEvent {
        var values: [String: Any] = ["RunesExercise": set.exercise, "RunesSet": set.set, "RunesCounted": set.counted]
        if let reps = set.reps { values["RunesReps"] = reps }
        if let seconds = set.seconds { values["RunesSeconds"] = seconds }
        if let weight = set.weight { values["RunesWeight"] = HKQuantity(unit: unit.mass, doubleValue: weight) }
        return HKWorkoutEvent(type: set.end > set.start ? .segment : .marker, dateInterval: DateInterval(start: set.start, end: set.end), metadata: values)
    }
}

private extension HealthActivity {
    var type: HKWorkoutActivityType {
        switch self {
        case .traditionalStrength: .traditionalStrengthTraining
        case .functionalStrength: .functionalStrengthTraining
        case .core: .coreTraining
        case .mixedCardio: .mixedCardio
        }
    }
}

private extension WeightUnit {
    var mass: HKUnit { self == .kg ? .gramUnit(with: .kilo) : .pound() }
}
