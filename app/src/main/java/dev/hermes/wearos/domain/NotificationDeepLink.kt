package dev.hermes.wearos.domain

/**
 * Where a notification's "Open session" lands (owner: *"it should go straight to that session,
 * not just open the app"* — including switching agents when the app sits on a different one).
 * Pure so the routing is testable without an Android context; [ChatSession] executes the plan.
 */
object NotificationDeepLink {

    enum class Route { OPEN, SWITCH_THEN_OPEN }

    /** The agent to switch to for [Route.SWITCH_THEN_OPEN]; "" for the others. */
    fun plan(currentProfile: String, chatProfile: String, chatKnown: Boolean): Pair<Route, String> {
        if (!chatKnown) return Route.OPEN to ""            // vanished/local-only id: plain open (no-op if gone)
        if (chatProfile.isEmpty() || chatProfile == currentProfile) return Route.OPEN to ""
        return Route.SWITCH_THEN_OPEN to chatProfile
    }
}
