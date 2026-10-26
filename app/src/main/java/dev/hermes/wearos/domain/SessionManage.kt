package dev.hermes.wearos.domain

import dev.hermes.wearos.data.ChatMeta

/**
 * Pure rules behind the Sessions long-press menu (owner: "hold a session — fork or delete, and
 * delete double-checks"). The actions themselves run through watchkit against `state.db` (see
 * `Watchkit.forkSession`), so what lives here — label wording and the local-mirror pick — is the
 * part worth pinning with unit tests.
 */
object SessionManage {

    /**
     * Watch-chat label for a forked session. watchkit already suffixes the STORE title " (fork)";
     * the chat label matches so the Sessions row and the Chats list tell the same story, clamped
     * to what a 480-face row can actually show.
     */
    fun chatLabel(title: String): String {
        val t = title.trim()
        if (t.isBlank()) return "fork"
        if (t.endsWith("(fork)")) return t
        return "${t.take(40).trimEnd()} (fork)"
    }

    /**
     * The one local chat that mirrors gateway session [sessionId] (`sessionTitle` is THE join
     * key between watch chats and gateway sessions, SPEC §3), or null when the row is a pure
     * desktop session with no watch mirror.
     */
    fun localMirror(chats: List<ChatMeta>, sessionId: String): ChatMeta? =
        chats.firstOrNull { it.sessionTitle == sessionId }
}
