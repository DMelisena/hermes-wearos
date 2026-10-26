package dev.hermes.wearos.domain

import dev.hermes.wearos.data.ChatMeta
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

/**
 * The pure half of the Sessions long-press menu (fork/delete, SPEC §12.4 follow-up): what the
 * forked chat is CALLED and which local chat a gateway row DOOMS when deleted. The watchkit calls
 * themselves are I/O and verified live; the rules here are the ones a wrist can notice.
 */
class SessionManageTest {

    @Test fun `fork label says fork`() {
        assertEquals("haiku about tide (fork)", SessionManage.chatLabel("haiku about tide"))
    }

    @Test fun `never double-suffixes`() {
        assertEquals("haiku about tide (fork)", SessionManage.chatLabel("haiku about tide (fork)"))
    }

    @Test fun `long titles clamp to what a row can show`() {
        val label = SessionManage.chatLabel("a".repeat(120))
        assert(label.length <= 40 + " (fork)".length)
        assert(label.endsWith(" (fork)"))
    }

    @Test fun `blank title still labels the fork`() {
        assertEquals("fork", SessionManage.chatLabel("   "))
    }

    private fun meta(id: String, session: String, profile: String = "wear") =
        ChatMeta(id = id, sessionTitle = session, profile = profile)

    @Test fun `mirror joins on sessionTitle, the SPEC 3 key`() {
        val chats = listOf(meta("c1", "wear-watch-aaa"), meta("c2", "wear-watch-bbb"))
        assertSame(chats[1], SessionManage.localMirror(chats, "wear-watch-bbb"))
    }

    @Test fun `desktop session with no mirror deletes alone`() {
        val chats = listOf(meta("c1", "wear-watch-aaa", "default"))
        assertNull(SessionManage.localMirror(chats, "api_1793017673_df876653"))
    }

    @Test fun `id that never joined is not a mirror (labels never match ids)`() {
        val chats = listOf(ChatMeta(id = "c1", sessionTitle = "wear-watch-x", label = "wear-watch-x"))
        assertNull(SessionManage.localMirror(chats, "something-else"))
    }
}
