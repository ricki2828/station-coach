import Foundation
import HealthKit

/// Owns the `HKWorkoutSession`. Activity type is `.crossTraining` (indoor): a race alternates running
/// with carries, sleds, ergs and wall balls, and HealthKit has no hybrid type. Indoor means no GPS.
/// The session is what keeps the app alive and lets CMBatchedSensorManager deliver.
final class WorkoutService: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
  private let store = HKHealthStore()
  private var session: HKWorkoutSession?
  private var builder: HKLiveWorkoutBuilder?

  var onHeartRate: ((Double) -> Void)?
  var onEvent: ((String, String) -> Void)?

  func requestAuthorization() async throws {
    let share: Set<HKSampleType> = [HKObjectType.workoutType()]
    let read: Set<HKObjectType> = [HKQuantityType(.heartRate)]
    try await store.requestAuthorization(toShare: share, read: read)
  }

  func start() async throws {
    let config = HKWorkoutConfiguration()
    config.activityType = .crossTraining
    config.locationType = .indoor
    let session = try HKWorkoutSession(healthStore: store, configuration: config)
    let builder = session.associatedWorkoutBuilder()
    builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
    session.delegate = self
    builder.delegate = self
    self.session = session
    self.builder = builder
    let now = Date()
    session.startActivity(with: now)
    try await builder.beginCollection(at: now)
  }

  func stop() async {
    session?.end()
    do {
      try await builder?.endCollection(at: Date())
      _ = try await builder?.finishWorkout()
    } catch {
      onEvent?("workout_finish_error", "\(error)")
    }
    session = nil
    builder = nil
  }

  // MARK: HKWorkoutSessionDelegate

  func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
    onEvent?("workout_state", "\(fromState.rawValue)->\(toState.rawValue)")
  }

  func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
    onEvent?("workout_error", "\(error)")
  }

  // MARK: HKLiveWorkoutBuilderDelegate

  func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

  func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
    let hrType = HKQuantityType(.heartRate)
    guard collectedTypes.contains(hrType) else { return }
    let unit = HKUnit.count().unitDivided(by: .minute())
    if let bpm = workoutBuilder.statistics(for: hrType)?.mostRecentQuantity()?.doubleValue(for: unit) {
      onHeartRate?(bpm)
    }
  }
}
