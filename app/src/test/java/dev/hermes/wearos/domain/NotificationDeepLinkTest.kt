package dev.hermes.wearos.domain

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Deep-link routing (OWNER BUG: notifications said "open app" and landed on whatever chat the
 * app happened to show — the ask: go STRAIGHT to the session the notice came from, switching
 * agents when the app sits on a different one).
 */
class NotificationDeepLinkTest {

    private fun plan(current: String, chatProfile: String, chatKnown: Boolean) =
        NotificationDeepLink.plan(current, chatProfile, chatKnown)

    @Test fun `same agent opens directly`() {
        assertEquals(
            NotificationDeepLink.Route.OPEN to "",
            plan("wear-demo", "wear-demo", chatKnown = true),
        )
    }

    @Test fun `cross agent switches to the chat's agent first`() {
        assertEquals(
            NotificationDeepLink.Route.SWITCH_THEN_OPEN to "redridge-treasurer",
            plan("wear-demo", "redridge-treasurer", chatKnown = true),
        )
    }

    @Test fun `unknown chat id never switches (plain open — no-op if it vanished)`() {
        assertEquals(
            NotificationDeepLink.Route.OPEN to "",
            plan("wear", "redridge-treasurer", chatKnown = false),
        )
    }

    @Test fun `local-only chat without a profile never switches`() {
        assertEquals(
            NotificationDeepLink.Route.OPEN to "",
            plan("wear", "", chatKnown = true),
        )
    }
}
