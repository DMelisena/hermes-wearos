package dev.hermes.wearos.domain

import dev.hermes.wearos.data.ChatMeta

/**
 * SESSION SEARCH (SPEC §12.4, owner batch 3: "new session plus a tap-to-search box, searchable via
 * on-watch Vosk voice or keyboard"). One query, two homes: the watch's OWN chats (titles + saved
 * transcripts, offline truth) and the gateway's full-history FTS index (watchkit `GET /search`,
 * per agent + the desktop profile). This file owns the merge + ranking so the screen stays
 * presentation and the ordering rules are unit-tested, not vibes.
 *
 * Ranking, deliberately boring: a chat whose TITLE matches beats a passing content mention (when
 * you type "vpn deploy" you mean the chat named that); then hit count; then recency. A watch chat
 * that mirrors a gateway session appears ONCE — under its local entry, which can open instantly.
 */
data class SessionHit(
    val id: String,
    val title: String,
    val profile: String,
    val snippet: String,
    val source: Source,
    /** Set for WATCH hits: the local chat to open (gateway hits go through adoption instead). */
    val watchChatId: String = "",
    val lastActiveMs: Long = 0L,
    val hits: Int = 0,
    val titleMatch: Boolean = false,
) {
    enum class Source { WATCH, GATEWAY }
}

object SessionSearch {
    const val MAX_RESULTS = 14

    /** Case-insensitive contains with a blank-safe rule (blank query = nothing, never everything). */
    fun matches(text: String, query: String): Boolean {
        val q = query.trim()
        if (q.isEmpty()) return false
        return text.contains(q, ignoreCase = true)
    }

    /** A one-line preview around the first match, so a wrist can see WHY a row matched. */
    fun preview(text: String, query: String, radius: Int = 48): String {
        val q = query.trim()
        if (q.isEmpty() || text.isBlank()) return text.trim().take(radius * 2)
        val idx = text.indexOf(q, ignoreCase = true)
        if (idx < 0) return text.trim().lineSequence().firstOrNull().orEmpty().take(radius * 2)
        val start = (idx - radius).coerceAtLeast(0)
        val end = (idx + q.length + radius).coerceAtMost(text.length)
        return buildString {
            if (start > 0) append("…")
            append(text, start, end)
            if (end < text.length) append("…")
        }.replace('\n', ' ')
    }

    /**
     * WATCH chats matching the query by label or transcript content, with the preview pulled from
     * whichever carried the match. `transcript` is injected (the store does file IO; tests do maps).
     */
    fun localHits(
        chats: List<ChatMeta>,
        query: String,
        transcript: (String) -> List<ChatMessage>,
    ): List<SessionHit> {
        val q = query.trim()
        if (q.isEmpty()) return emptyList()
        return chats.mapNotNull { c ->
            val titleHit = matches(c.label, q) || matches(c.sessionTitle, q)
            var snippet = ""
            var contentHit = false
            if (!titleHit) {
                // Newest-first scan: the freshest matching line is the most useful preview.
                val msgs = runCatching { transcript(c.id) }.getOrDefault(emptyList())
                msgs.asReversed().firstOrNull { matches(it.text, q) }?.let {
                    contentHit = true
                    snippet = preview(it.text, q)
                }
            } else {
                snippet = c.label
            }
            if (!titleHit && !contentHit) return@mapNotNull null
            SessionHit(
                id = c.id,
                title = c.label.ifBlank { c.sessionTitle },
                profile = c.profile,
                snippet = snippet,
                source = SessionHit.Source.WATCH,
                watchChatId = c.id,
                lastActiveMs = c.updatedAt,
                hits = if (titleHit) 2 else 1, // a title counts double: same currency as gateway hits
                titleMatch = titleHit,
            )
        }
    }

    /**
     * Merge + rank (see file header). Dedup key is the gateway session id when known (a watch chat
     * adopted from the gateway carries it) so the instant-open WATCH row wins over the gateway row.
     */
    fun merge(local: List<SessionHit>, gateway: List<SessionHit>, cap: Int = MAX_RESULTS): List<SessionHit> {
        val bySession = LinkedHashMap<String, SessionHit>()
        for (h in local) bySession[h.id] = h
        for (h in gateway) {
            val existing = bySession[h.id]
            if (existing != null) {
                // Keep the watch row (opens offline, instantly) but absorb the server's richer signal.
                bySession[h.id] = existing.copy(
                    snippet = existing.snippet.ifBlank { h.snippet },
                    hits = maxOf(existing.hits, h.hits),
                    titleMatch = existing.titleMatch || h.titleMatch,
                    lastActiveMs = maxOf(existing.lastActiveMs, h.lastActiveMs),
                )
            } else {
                bySession[h.id] = h
            }
        }
        return bySession.values.sortedWith(
            compareByDescending<SessionHit> { it.titleMatch }
                .thenByDescending { it.hits }
                .thenByDescending { it.lastActiveMs },
        ).take(cap)
    }
}
