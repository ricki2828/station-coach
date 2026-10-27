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
  /// The session ended or failed without `stop()` being called (another workout app, an error, auth revoked).
  var onUnexpectedEnd: ((String) -> Void)?
  private var stopping = false

  func requestAuthorization() async throws {
    let share: Set<HKSampleType> = [HKObjectType.workoutType()]
    let read: Set<HKObjectType> = [HKQuantityType(.heartRate)]
    try await store.requestAuthorization(toShare: share, read: read)
  }

  /// HealthKit hides whether a read was declined, but it does say whether saving workouts was.
  var workoutShareDenied: Bool { store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingDenied }

  /// An earlier run that was killed can leave a workout session alive at the system level. End it first.
  func endOrphanedSession() async {
    do {
      if let orphan = try await store.recoverActiveWorkoutSession() {
        onEvent?("orphan_session", "ending recovered session in state \(orphan.state.rawValue)")
        orphan.end()
      }
    } catch {
      onEvent?("orphan_check_error", "\(error)")
    }
  }

  struct RecoveryError: Error, CustomStringConvertible {
    let description: String
  }

  /// Reattaches to the workout session the system kept alive across a relaunch (called from `handleActiveWorkoutRecovery`).
  /// The builder keeps collecting; only the delegates need setting again. Not verifiable without a watch.
  func recover() async throws {
    guard let recovered = try await store.recoverActiveWorkoutSession() else { throw RecoveryError(description: "no active workout session") }
    guard recovered.state != .ended, recovered.state != .stopped else { throw RecoveryError(description: "recovered session already ended") }
    let builder = recovered.associatedWorkoutBuilder()
    if builder.dataSource == nil {
      builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: recovered.workoutConfiguration)
    }
    recovered.delegate = self
    builder.delegate = self
    session = recovered
    self.builder = builder
    stopping = false
    onEvent?("workout_recovered", "state \(recovered.state.rawValue)")
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
    stopping = false
    let now = Date()
    session.startActivity(with: now)
    try await builder.beginCollection(at: now)
  }

  func stop() async {
    stopping = true
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
    if !stopping, toState == .ended || toState == .stopped { onUnexpectedEnd?("Workout session ended") }
  }

  func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
    onEvent?("workout_error", "\(error)")
    if !stopping { onUnexpectedEnd?("Workout session failed") }
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
