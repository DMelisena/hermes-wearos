package dev.hermes.wearos.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * THE OVERLAY'S MEMORY (SPEC §12.3, owner: "I like to use the slash BTW and the slash steer a
 * lot"). What the RECENTS section ranks by has to be a decision, not a vibe: frequency matters,
 * but a command used 40 times last week must not beat the one used a minute ago, and one fresh
 * experiment has to be able to surface at all. Half-life (an hour) + log-damped counts do exactly
 * that — these tests pin the crossover instead of trusting the curve.
 */
class CommandUsageTest {

    private val hour = 3_600_000L

    @Test fun `recents rank by frequency with an hour half-life on recency`() {
        val now = 10 * hour
        var usages = emptyMap<String, CommandStat>()
        repeat(10) { usages = CommandUsage.record(usages, "compact", now - 6 * hour) }
        repeat(2) { usages = CommandUsage.record(usages, "steer", now - 60_000L) }
        usages = CommandUsage.record(usages, "btw", now)

        val top = CommandUsage.topRecents(usages, now)
        // What the curve GUARANTEES: anything used now outranks a stale favourite (6 half-lives
        // old), and inside the same fresh window frequency still decides.
        assertTrue("one use just now beats ten an hour ago", top.indexOf("btw") < top.indexOf("compact"))
        assertTrue("two uses a minute ago beat ten an hour ago", top.indexOf("steer") < top.indexOf("compact"))
        assertEquals("steer", top.first())
    }

    @Test fun `the just-used command always survives eviction`() {
        var usages = emptyMap<String, CommandStat>()
        val now = 100_000L
        repeat(CommandUsage.MAX_TRACKED + 10) { i ->
            usages = CommandUsage.record(usages, "cmd$i", now + i)
        }
        assertEquals(CommandUsage.MAX_TRACKED, usages.size)
        assertTrue(usages.containsKey("cmd${CommandUsage.MAX_TRACKED + 9}"))
    }

    @Test fun `memory round-trips the persisted line format`() {
        val now = 5_000L
        val usages = CommandUsage.record(CommandUsage.record(emptyMap(), "/steer", now), "btw", now + 1)
        val raw = CommandUsage.encode(usages)
        assertEquals("btw|1|5001\nsteer|1|5000", raw.lines().sorted().joinToString("\n"))
        val back = CommandUsage.decode(raw)
        assertEquals(usages.keys, back.keys)
        assertEquals(1, back.getValue("steer").count)
    }

    @Test fun `a corrupt store falls back to empty, never a crash`() {
        assertEquals(emptyMap<String, CommandStat>(), CommandUsage.decode(null))
        assertEquals(emptyMap<String, CommandStat>(), CommandUsage.decode(""))
        assertEquals(emptyMap<String, CommandStat>(), CommandUsage.decode("garbage\nsteer|nope|nope\n||"))
        // Forward-compatible: extra fields after the third pipe are ignored, not rejected.
        val tolerant = CommandUsage.decode("steer|3|123|v2")
        assertEquals(3, tolerant.getValue("steer").count)
    }

    @Test fun `slash prefix and case never split one command into two memories`() {
        var usages = emptyMap<String, CommandStat>()
        usages = CommandUsage.record(usages, "/Steer", 1L)
        usages = CommandUsage.record(usages, "  steer ", 2L)
        assertEquals(1, usages.size)
        assertEquals(2, usages.getValue("steer").count)
        assertEquals("a blank name is a no-op, not a new memory", usages, CommandUsage.record(usages, "   ", 3L))
    }

    @Test fun `the overlay asks for six recents, not the whole store`() {
        var usages = emptyMap<String, CommandStat>()
        for (i in 0 until 12) usages = CommandUsage.record(usages, "c$i", 1_000L + i)
        assertEquals(CommandUsage.RECENTS, CommandUsage.topRecents(usages, 10_000L).size)
    }
}
