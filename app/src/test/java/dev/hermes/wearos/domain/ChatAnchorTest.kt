package dev.hermes.wearos.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Bottom-anchor row-count math (walkthrough: transcript must STAY at the bottom across send /
 * stream / stop / approval / chat switch / overlay dismiss). The index ChatScreen scrolls to must
 * always be the LAST rendered row of ChatScreen's ScalingLazyColumn.
 */
class ChatAnchorTest {

    @Test fun `bare chat is just the header row`() {
        assertEquals(0, ChatAnchor.bottomIndex(messageCount = 0))
    }

    @Test fun `empty hint sits between header and the (missing) messages`() {
        assertEquals(1, ChatAnchor.bottomIndex(messageCount = 0, showEmptyHint = true))
    }

    @Test fun `messages push the anchor down one row each`() {
        assertEquals(4, ChatAnchor.bottomIndex(messageCount = 4))
    }

    @Test fun `approval live and status rows each add one`() {
        assertEquals(5, ChatAnchor.bottomIndex(messageCount = 4, hasApproval = true))
        assertEquals(5, ChatAnchor.bottomIndex(messageCount = 4, hasLive = true))
        assertEquals(5, ChatAnchor.bottomIndex(messageCount = 4, hasStatus = true))
        assertEquals(7, ChatAnchor.bottomIndex(messageCount = 4, hasApproval = true, hasLive = true, hasStatus = true))
    }

    @Test fun `voice send settle sequence walks the anchor to the bottom every time`() {
        // idle → user asks → stream deltas → stop marker (the exact "scrolls to the top" complaint)
        assertEquals(2, ChatAnchor.bottomIndex(2))                                        // 2 msgs
        assertEquals(3, ChatAnchor.bottomIndex(3))                                        // user msg lands
        assertTrue(ChatAnchor.bottomIndex(3, hasLive = true) > ChatAnchor.bottomIndex(3)) // live row
        assertEquals(4, ChatAnchor.bottomIndex(4, hasStatus = false))                     // stop adds "— stopped —"
    }

    @Test fun `empty hint only shows on a truly idle empty chat`() {
        assertTrue(ChatAnchor.showEmptyHint(0, "", false))
        assertFalse(ChatAnchor.showEmptyHint(0, "partial answer", false))  // streaming already
        assertFalse(ChatAnchor.showEmptyHint(0, "", true))                 // approval pending
        assertFalse(ChatAnchor.showEmptyHint(1, "", false))                // has history
    }

    @Test fun `negative message counts can't underflow the index`() {
        assertEquals(0, ChatAnchor.bottomIndex(-5))
    }

    // ── QUESTION PIN (owner batch 7: "scroll the viewport up a little so you can actually
    // see what the question was and the information come back") ──
    @Test fun `the question row is the last user message shifted past the header`() {
        // Rows: header · messages · (approval/live/status). User message index i → row i+1.
        assertEquals(1, ChatAnchor.questionRow(0))
        assertEquals(3, ChatAnchor.questionRow(2))
    }

    @Test fun `no user turn means no pin target - the caller keeps the bottom anchor`() {
        assertNull(ChatAnchor.questionRow(-1))
    }
}
