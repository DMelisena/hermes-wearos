package dev.hermes.wearos.domain

import dev.hermes.wearos.data.ChatMeta
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * THE SEARCH BOX'S RULES (SPEC §12.4, owner: "tap-to-search box … Vosk voice or keyboard"). The
 * screen merges; THESE decide. What has to stay true no matter what the store contains: a chat
 * NAMED what you typed beats a chat that merely mentions it, one watch chat never shows twice
 * because the gateway also lists it, and a preview shows the matched words rather than the text's
 * first line (the point is recognition, not browsing).
 */
class SessionSearchTest {

    private fun chat(id: String, label: String, profile: String = "wear", at: Long = 1000L) =
        ChatMeta(id = id, sessionTitle = "$id-session", label = label, updatedAt = at, profile = profile)

    private fun msgs(vararg text: String) =
        text.mapIndexed { i, t -> ChatMessage(i.toLong(), ChatMessage.Role.User, t) }

    private val transcripts = mapOf(
        "a" to msgs("setup the tailnet failover for the watch", "unrelated"),
        "b" to msgs("nothing to see"),
        "c" to msgs("we discussed the ORB DIAL wedges today"),
    )

    @Test fun `a blank query is nothing, not everything`() {
        val chats = listOf(chat("a", "ops"), chat("b", "home"))
        assertEquals(emptyList<SessionHit>(), SessionSearch.localHits(chats, "   ") { transcripts[it].orEmpty() })
        assertFalse(SessionSearch.matches("anything", ""))
    }

    @Test fun `label matches and transcript matches both surface`() {
        val chats = listOf(chat("a", "vpn deploy"), chat("b", "home"), chat("c", "chatting"))
        val hits = SessionSearch.localHits(chats, "failover") { transcripts[it].orEmpty() }
        assertEquals(listOf("a"), hits.map { it.id })
        val byLabel = SessionSearch.localHits(chats, "vpn") { transcripts[it].orEmpty() }
        assertEquals(listOf("a"), byLabel.map { it.id })
        assertTrue("a label hit counts as a title hit", byLabel.single().titleMatch)
    }

    @Test fun `case never splits matches — dictated text is lowercase, typed text is not`() {
        val chats = listOf(chat("c", "notes"))
        val hits = SessionSearch.localHits(chats, "Orb Dial") { transcripts[it].orEmpty() }
        assertEquals(1, hits.size)
        assertTrue(hits.single().snippet.contains("ORB DIAL"))
    }

    @Test fun `preview brackets the matched words for recognition`() {
        val text = "line one\nthe important FAILSAFE setting lives here\nline three"
        val p = SessionSearch.preview(text, "failsafe")
        assertTrue(p.contains("FAILSAFE"))
        assertTrue("newlines collapse for a one-line row", !p.contains('\n'))
        // Match near the start: no ellipsis in front, radius respected behind.
        val p2 = SessionSearch.preview("alpha beta gamma", "alpha", radius = 4)
        assertEquals("alpha bet…", p2)
    }

    @Test fun `title matches outrank content mentions, then hits, then recency`() {
        val local = listOf(
            SessionHit("l1", "mention only", "wear", "…orb dial…", SessionHit.Source.WATCH, "l1", 9000, 1, false),
            SessionHit("l2", "named orb dial", "wear", "named orb dial", SessionHit.Source.WATCH, "l2", 1000, 2, true),
        )
        val gateway = listOf(
            SessionHit("g1", "orb dial planning", "wear", "the [orb dial] ring", SessionHit.Source.GATEWAY, lastActiveMs = 5000, hits = 7, titleMatch = true),
            SessionHit("g2", "old chat", "wear", "one [orb dial] mention", SessionHit.Source.GATEWAY, lastActiveMs = 8000, hits = 3, titleMatch = false),
            SessionHit("g3", "stale title", "wear", "named, no mentions", SessionHit.Source.GATEWAY, lastActiveMs = 100, hits = 0, titleMatch = true),
        )
        val order = SessionSearch.merge(local, gateway).map { it.id }
        // Title matches first — among them by hits (g1 7×, l2 2×, g3 0×) — then content by hits.
        assertEquals(listOf("g1", "l2", "g3", "g2", "l1"), order)
    }

    @Test fun `a watch chat that mirrors a gateway session shows once, as the watch row`() {
        // Same id on both sides: adoption keeps the gateway session id.
        val local = listOf(SessionHit("s1", "my chat", "wear", "", SessionHit.Source.WATCH, "s1", 5000, 1, false))
        val gateway = listOf(SessionHit("s1", "my chat", "wear", "[rich] server snippet", SessionHit.Source.GATEWAY, lastActiveMs = 6000, hits = 4, titleMatch = true))
        val merged = SessionSearch.merge(local, gateway)
        assertEquals(1, merged.size)
        val one = merged.single()
        assertEquals(SessionHit.Source.WATCH, one.source)
        assertEquals("opens instantly offline", "s1", one.watchChatId)
        assertTrue("server signals absorbed", one.titleMatch && one.hits == 4 && one.lastActiveMs == 6000L)
        assertEquals("server snippet fills an empty local one", "[rich] server snippet", one.snippet)
    }

    @Test fun `results cap so a 200-hit query stays a wrist-sized list`() {
        val many = (1..40).map {
            SessionHit("g$it", "chat $it", "wear", "x", SessionHit.Source.GATEWAY, lastActiveMs = it.toLong(), hits = it, titleMatch = false)
        }
        val merged = SessionSearch.merge(emptyList(), many)
        assertEquals(SessionSearch.MAX_RESULTS, merged.size)
        assertEquals("highest hits first inside the cap", "g40", merged.first().id)
    }

    @Test fun `a transcript file that vanished mid-search is a miss, not a crash`() {
        val chats = listOf(chat("boom", "wreck"))
        val hits = SessionSearch.localHits(chats, "wreck") { throw java.io.FileNotFoundException("gone") }
        assertTrue("label still matched, transcript absence is invisible", hits.size == 1 && hits.single().titleMatch)
    }
}
