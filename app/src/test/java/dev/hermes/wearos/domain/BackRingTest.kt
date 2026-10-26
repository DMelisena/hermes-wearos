package dev.hermes.wearos.domain

import dev.hermes.wearos.Screen
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The back-button ring (owner batch 6: *"chat to sessions to agents, then back to chat again —
 * the app shouldn't really quit unless I hit the home button"*). Pinned: the walk order, the
 * hub-return of side screens, and the full loop returning to Chat without any quit step.
 */
class BackRingTest {

    @Test fun `chat back opens sessions`() {
        assertEquals(BackRing.Action.ToSessions, BackRing.action(Screen.Chat))
    }

    @Test fun `sessions back opens the agent picker`() {
        assertEquals(BackRing.Action.ToAgents, BackRing.action(Screen.Sessions))
    }

    @Test fun `side screens rejoin the ring at chat`() {
        assertEquals(BackRing.Action.ToChat, BackRing.action(Screen.Chats))
        assertEquals(BackRing.Action.ToChat, BackRing.action(Screen.Settings))
    }

    @Test fun `the ring loops — three presses from chat land back on chat`() {
        // Chat -back-> Sessions -back-> Agents (picker overlay; its own back closes onto Chat)
        // The overlay close is not BackRing's (it is the topmost-layer cascade) — the ring only
        // sees SURFACES, so the loop simulates: Chat -> Sessions -> Agents-overlay -> Chat.
        var screen = Screen.Chat
        screen = when (BackRing.action(screen)) {
            BackRing.Action.ToSessions -> Screen.Sessions
            BackRing.Action.ToAgents -> Screen.Chat // picker overlay closes onto Chat (MainActivity)
            BackRing.Action.ToChat -> Screen.Chat
        }
        assertEquals(Screen.Sessions, screen) // after press 1
        screen = Screen.Chat // press 2 opened the picker; press 3 closed it onto Chat
        assertEquals(BackRing.Action.ToSessions, BackRing.action(screen)) // ring resumes from Chat
    }

    @Test fun `no action finishes the app — the enum has no quit leg`() {
        // The ring's Action set itself is the proof: nothing here can exit the activity.
        assertEquals(
            setOf("ToSessions", "ToAgents", "ToChat"),
            BackRing.Action.entries.map { it.name }.toSet(),
        )
    }
}
