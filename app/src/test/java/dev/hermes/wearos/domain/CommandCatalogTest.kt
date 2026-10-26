package dev.hermes.wearos.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * THE THREE SOURCES, MERGED (SPEC §12.3): built-ins ⊕ watchkit's pushed rows ⊕ skills that ride in
 * the same payload. What matters for the wrist is that a broken or foreign payload can never blank
 * the overlay — the built-in floor always stands — and that the capability flags survive the
 * round trip, because those are what dim `/steer` on a gateway that cannot steer.
 */
class CommandCatalogTest {

    private val pushed = """
        {"commands":[
          {"name":"steer","args":"your guidance","desc":"gateway says steer","honored":"steer","group":"commands","requires":"run_steer"},
          {"name":"vet","args":"<diff>","desc":"run the vet skill","honored":"skill","group":"skills","source":"wear"},
          {"name":"bogus","honored":"teleport","group":"nope"}
        ],"capabilities":{"run_steer":true,"session_fork":false}}
    """.trimIndent()

    @Test fun `pushed rows parse with gates and provenance`() {
        val c = CommandCatalog.parse(pushed)
        assertEquals(3, c.entries.size)
        val steer = c.entries.first { it.name == "steer" }
        assertEquals(CommandKind.Steer, steer.honored)
        assertEquals("run_steer", steer.requires)
        assertEquals(mapOf("run_steer" to true, "session_fork" to false), c.capabilities)
    }

    @Test fun `unknown honored and group degrade to the honest bucket, never a crash`() {
        val bogus = CommandCatalog.parse(pushed).entries.first { it.name == "bogus" }
        assertEquals(CommandKind.Prompt, bogus.honored) // "teleport" is not a thing the watch can do
        assertEquals(CommandGroup.Commands, bogus.group)
    }

    @Test fun `gateway rows win over built-ins on the same name`() {
        val merged = CommandCatalog.merge(SlashCommands.BUILTIN, CommandCatalog.parse(pushed).entries)
        val steer = merged.first { it.name == "steer" }
        assertEquals("gateway says steer", steer.help)
        assertEquals(1, merged.count { it.name == "steer" })
        assertTrue("built-ins the gateway does not know survive", merged.any { it.name == "sessions" })
    }

    @Test fun `a corrupt or absent payload leaves the built-in floor intact`() {
        assertEquals(0, CommandCatalog.parse(null).entries.size)
        assertEquals(0, CommandCatalog.parse("{ not json").entries.size)
        assertEquals(0, CommandCatalog.parse("""{"commands":"nope"}""").entries.size)
        val merged = CommandCatalog.merge(SlashCommands.BUILTIN, CommandCatalog.parse("{ broken").entries)
        assertEquals(SlashCommands.BUILTIN.map { it.name }, merged.map { it.name })
    }

    @Test fun `rows round-trip through the stored json with capabilities`() {
        val rows = SlashCommands.BUILTIN.take(3)
        val json = CommandCatalog.gatewayJson(rows, mapOf("run_steer" to true, "session_fork" to false))
        val back = CommandCatalog.parse(json)
        assertEquals(rows.map { it.name }, back.entries.map { it.name })
        assertEquals(rows.map { it.honored }, back.entries.map { it.honored })
        assertEquals(mapOf("run_steer" to true, "session_fork" to false), back.capabilities)
    }

    @Test fun `quotes in gateway descriptions cannot break the stored json`() {
        val rows = listOf(
            CommandEntry(
                name = "quoted",
                help = "the \"hardest\" problem \\ solved",
                honored = CommandKind.Prompt,
            ),
        )
        val back = CommandCatalog.parse(CommandCatalog.gatewayJson(rows))
        assertEquals(1, back.entries.size)
        assertEquals("the 'hardest' problem \\\\ solved", back.entries[0].help)
    }

    @Test fun `watchkit rows map by name with the slash stripped`() {
        val rows = CommandCatalog.fromWatchkit(
            listOf(dev.hermes.wearos.net.CommandInfo(name = "/compact", desc = "compress", honored = "prompt", group = "commands")),
        )
        assertEquals("compact", rows.single().name)
        assertEquals(CommandKind.Prompt, rows.single().honored)
    }
}
