package dev.hermes.wearos.domain

/**
 * ON-WATCH COMMAND MEMORY (owner batch 3: the 6:00 overlay should "remember the ones I use most").
 * A pure score: usage count with recency decay, so `/steer` used every day floats to the top while
 * a one-time `/compact` sinks — no cloud, no sync, survives restarts through DataStore.
 *
 * PERSISTED SHAPE is one line per command, `name|count|lastUsedMs` (see [encode]/[decode]): cheap,
 * hand-editable via the dev hook, and forward-compatible (unknown fields after the third pipe are
 * ignored, garbage lines dropped — a corrupt store falls back to empty, never crashes the dial).
 *
 * Cap at [MAX_TRACKED]: the overlay shows the top [RECENTS] anyway; the ceiling is settings-friendly
 * (the owner asked for a bounded memory, not a database).
 */
data class CommandStat(val name: String, val count: Int, val lastUsedMs: Long)

object CommandUsage {
    const val MAX_TRACKED = 40
    const val RECENTS = 6

    /** Half-life for the recency boost, in ms (an hour old = half the boost). */
    const val HALF_LIFE_MS = 3_600_000L

    /** Record one use of "/name" (the leading slash is stripped). */
    fun record(usages: Map<String, CommandStat>, name: String, nowMs: Long): Map<String, CommandStat> {
        val key = name.trim().removePrefix("/").lowercase()
        if (key.isEmpty()) return usages
        val prev = usages[key]
        val next = CommandStat(key, (prev?.count ?: 0) + 1, nowMs)
        return buildMap {
            putAll(usages)
            put(key, next)
            if (size > MAX_TRACKED) {
                // Evict the coldest by score, keeping the just-used entry.
                val drop = values.filter { it.name != key }.minByOrNull { scoreAt(it, nowMs) }
                if (drop != null) remove(drop.name)
            }
        }
    }

    /** Recency-weighted popularity: count × 2^(-age/half-life), log-damped so one fresh command
     *  can dethrone a long-time favourite on a single use (the owner is trying things today). */
    fun scoreAt(stat: CommandStat, nowMs: Long): Double {
        val age = (nowMs - stat.lastUsedMs).coerceAtLeast(0L).toDouble()
        val recency = Math.pow(0.5, age / HALF_LIFE_MS)
        return (1.0 + Math.log1p(stat.count.toDouble())) * (0.25 + 0.75 * recency)
    }

    /** Overlay "RECENTS" rows, most-used first; at most [RECENTS]. */
    fun topRecents(usages: Map<String, CommandStat>, nowMs: Long, limit: Int = RECENTS): List<String> =
        usages.values.sortedByDescending { scoreAt(it, nowMs) }.take(limit).map { it.name }

    fun encode(usages: Map<String, CommandStat>): String =
        usages.values.joinToString("\n") { "${it.name}|${it.count}|${it.lastUsedMs}" }

    fun decode(raw: String?): Map<String, CommandStat> {
        if (raw.isNullOrBlank()) return emptyMap()
        return raw.lineSequence().mapNotNull { line ->
            val parts = line.trim().split("|")
            if (parts.size < 3) return@mapNotNull null
            val name = parts[0].trim().removePrefix("/").lowercase()
            val count = parts[1].trim().toIntOrNull() ?: return@mapNotNull null
            val last = parts[2].trim().toLongOrNull() ?: return@mapNotNull null
            if (name.isEmpty() || count <= 0) return@mapNotNull null
            name to CommandStat(name, count, last)
        }.toMap()
    }
}
