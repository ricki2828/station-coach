import CoachKit
import SwiftUI

extension ScreenCatalog {
  private static func coachW(_ name: String, _ view: some View) -> CatalogEntry {
    CatalogEntry(name: "phone-\(name)", size: nil, view: AnyView(view.frame(width: Theme.phone.width)))
  }

  /// The AI coach screens (flag off in the app; these render the screens as they would look). Not part of `all`: the
  /// coach tests render them with `CoachScreenshotTests`.
  public static var coachScreens: [CatalogEntry] {
    let last = CoachFactRow.exampleFacts
    let changed = CoachFactRow.rows(for: last).filter { $0.id == "reference" }
    let reply = "Your total of 41:12 came in 1:12 over the 40:00 plan, and Sled push gave back most of it: 4:20 against a 3:30 target. Next, Half sim."
    return [
      coachW("coach-offer", CoachOfferCard()),
      coachW("coach-facts", CoachFactsScreen(facts: last)),
      coachW("coach-facts-xl", CoachFactsScreen(facts: last).environment(\.dynamicTypeSize, .xxxLarge)),
      coachW("coach-offer-xl", CoachOfferCard().environment(\.dynamicTypeSize, .xxxLarge)),
      coachW("coach-facts-example", CoachFactsScreen(facts: last, mode: .example)),
      coachW("coach-on", CoachSettingsCard(state: .on(since: "2026-10-27"))),
      coachW("coach-on-failed", CoachFactsScreen(facts: last, mode: .failed)),
      coachW("coach-revoked", CoachSettingsCard(state: .revoked(deleted: 6))),
      coachW("coach-revoked-pending", CoachSettingsCard(state: .revokedPending)),
      coachW("coach-reset", CoachSettingsCard(state: .reset)),
      coachW("coach-reconsent", CoachReconsentScreen(changed: changed)),
      coachW("debrief-queued", DebriefCard(display: .queued)),
      coachW("debrief-loading", DebriefCard(display: .loading)),
      coachW("debrief-reply", DebriefCard(display: .reply(reply))),
      coachW("debrief-error", DebriefCard(display: .error)),
      coachW("debrief-cap", DebriefCard(display: .cap)),
    ]
  }
}
