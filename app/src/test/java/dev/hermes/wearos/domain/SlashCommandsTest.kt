package dev.hermes.wearos.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * THE HONEST CATALOG (SPEC §12.3). The constraint that shapes the whole feature: the Runs API does
 * NOT dispatch slash commands — `POST /v1/runs` hands `input` to the MODEL — so a row that merely
 * looks like `/steer` must never be fired at the gateway as text and called a command. Every
 * built-in therefore carries what the WATCH does with it, and the list is checked here so nobody
 * adds a decorative row that cannot be honored.
 */
class SlashCommandsTest {

    @Test fun `the owner's two favourites exist and are honored by real routes`() {
        val steer = SlashCommands.BUILTIN.first { it.name == "steer" }
        val btw = SlashCommands.BUILTIN.first { it.name == "btw" }
        assertEquals(CommandKind.Steer, steer.honored)
        assertEquals(CommandKind.Side, btw.honored)
        assertEquals("run_steer", steer.requires)
        assertEquals("session_fork", btw.requires)
    }

    @Test fun `no built-in pretends to be a dispatched command`() {
        // `None` would render a row that does nothing at all; only real actions belong here.
        SlashCommands.BUILTIN.forEach { e ->
            assertTrue("row /${e.name} has no honoring action", e.honored != CommandKind.None)
            assertTrue("row /${e.name} must say how it is honored", e.honored != CommandKind.Prompt || e.name == "compact")
        }
    }

    @Test fun `invocation carries the arg hint so a pick can prefill`() {
        assertEquals("/stop", SlashCommands.BUILTIN.first { it.name == "stop" }.invocation)
        assertEquals("/steer your guidance", SlashCommands.BUILTIN.first { it.name == "steer" }.invocation)
    }

    @Test fun `a lone slash draft opens the overlay instead of asking the model`() {
        assertTrue(SlashCommands.looksLikeSlashDraft("/"))
        assertTrue(SlashCommands.looksLikeSlashDraft("/st"))
        // With args the command is complete: send routes it through the catalog, no overlay.
        assertFalse(SlashCommands.looksLikeSlashDraft("/steer fix it"))
        // Once there is prose after the verb, or a second token, the wrist means it as text.
        assertFalse(SlashCommands.looksLikeSlashDraft("/steer fix the /table width"))
        assertFalse(SlashCommands.looksLikeSlashDraft("check /status please"))
        assertFalse(SlashCommands.looksLikeSlashDraft("http://x/y"))
        assertFalse(SlashCommands.looksLikeSlashDraft(""))
        assertFalse(SlashCommands.looksLikeSlashDraft("/not a command at all here"))
        assertFalse(SlashCommands.looksLikeSlashDraft("/Bad Name"))
    }

    @Test fun `a skill-heavy agent browses a preview and searches the whole list`() {
        val skills = (1..184).map { CommandEntry("skill$it", help = "does thing $it", honored = CommandKind.Skill, group = CommandGroup.Skills) }
        assertEquals(SlashCommands.SKILL_PREVIEW, SlashCommands.skillSection(skills, "").size)
        assertEquals(SlashCommands.SKILL_PREVIEW, SlashCommands.skillSection(skills, "   ").size)
        assertEquals(184, SlashCommands.skillSection(skills, "skill17").size)
        // The preview is a prefix, never a shuffle: the section title can honestly say "+N more".
        assertEquals("skill1", SlashCommands.skillSection(skills, "").first().name)
    }

    @Test fun `filter matches prefix first, then names and help text`() {
        val all = SlashCommands.BUILTIN
        val byPrefix = SlashCommands.matches("/st", all).map { it.name }
        assertTrue("the two st-verbs are in there", byPrefix.containsAll(listOf("steer", "stop")))
        val prefixRun = byPrefix.takeWhile { it.startsWith("st") }
        assertEquals("prefix matches come first", prefixRun.size, byPrefix.count { it.startsWith("st") })
        assertTrue("help text is searchable too", byPrefix.size > prefixRun.size)
        // help text is searchable too: the owner remembers what a thing DOES, not its name
        assertTrue(SlashCommands.matches("branch", all).any { it.name == "fork" })
        assertEquals(all, SlashCommands.matches("  ", all))
    }
}
