package dev.hermes.wearos.domain

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject

/**
 * THE THREE SOURCES, MERGED (SPEC §12.3): curated built-ins + the gateway's own command catalog
 * (watchkit `GET /catalog`, which reads the gateway where the watch can't reach it) + live skills.
 *
 * Why JSON survives the merge: a corrupt/foreign catalog must never blank the overlay — the watch
 * always has the built-in floor. Duplicate names resolve in the order above (gateway wins over
 * built-in, skills win over both, because the agent is the authority on its own skills).
 *
 * The wire format is `CommandInfo` (see net/Watchkit.kt), kept flat for hand-editing:
 * `{"commands":[{"name":"steer","args":"your guidance","desc":"…","honored":"steer","group":"commands","requires":"run_steer"}]}`
 */
object CommandCatalog {

    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    /** Parse a pushed/pasted catalog JSON. Anything unparseable → empty (built-ins still show). */
    fun parse(raw: String?): Catalog {
        val text = raw?.trim()?.takeIf { it.isNotEmpty() } ?: return Catalog.EMPTY
        return runCatching {
            val root = json.parseToJsonElement(text).jsonObject
            var capabilities: Map<String, Boolean> = emptyMap()
            val caps = root["capabilities"]?.jsonObject?.mapNotNull { (k, v) ->
                val b = v.toString().trim().let { it == "true" || it == "false" }
                if (b) k to (v.toString().trim() == "true") else null
            }?.toMap().orEmpty()
            capabilities = caps
            val entries = root["commands"]?.jsonArray?.mapNotNull { el ->
                val o = el.jsonObject
                val name = (o["name"]?.toString()?.trim()?.trim('"') ?: "").removePrefix("/")
                if (name.isEmpty()) return@mapNotNull null
                CommandEntry(
                    name = name,
                    argsHint = o["args"]?.toString()?.trim('"').orEmpty(),
                    help = o["desc"]?.toString()?.trim('"').orEmpty(),
                    honored = o["honored"]?.toString()?.trim('"')?.let { runCatching { CommandKind.valueOf(it.replaceFirstChar(Char::uppercase)) }.getOrNull() }
                        ?: CommandKind.Prompt,
                    group = o["group"]?.toString()?.trim('"')?.let { runCatching { CommandGroup.valueOf(it.replaceFirstChar(Char::uppercase)) }.getOrNull() }
                        ?: CommandGroup.Commands,
                    requires = o["requires"]?.toString()?.trim('"')?.takeIf { it.isNotBlank() && it != "null" },
                    source = o["source"]?.toString()?.trim('"').orEmpty(),
                )
            }.orEmpty()
            Catalog(entries, capabilities)
        }.getOrElse { Catalog.EMPTY }
    }

    /** watchkit `GET /catalog` rows → overlay entries. Unknown `honored` degrades to `Prompt` —
     *  the honest bucket, never a silent local failure. */
    fun fromWatchkit(rows: List<dev.hermes.wearos.net.CommandInfo>): List<CommandEntry> =
        rows.map { info ->
            CommandEntry(
                name = info.name.removePrefix("/"),
                argsHint = info.args,
                help = info.desc,
                honored = runCatching { CommandKind.valueOf(info.honored.replaceFirstChar(Char::uppercase)) }
                    .getOrDefault(CommandKind.Prompt),
                group = runCatching { CommandGroup.valueOf(info.group.replaceFirstChar(Char::uppercase)) }
                    .getOrDefault(CommandGroup.Commands),
                requires = info.requires?.takeIf { it.isNotBlank() },
                source = info.source,
            )
        }

    /** Gateway rows + capability flags → the stored JSON shape [parse] reads back. */
    fun gatewayJson(rows: List<CommandEntry>, capabilities: Map<String, Boolean> = emptyMap()): String =
        "{\"commands\":[" + rows.joinToString(",") { e ->
            "{\"name\":\"${e.name}\",\"args\":\"${esc(e.argsHint)}\",\"desc\":\"${esc(e.help)}\"," +
                "\"honored\":\"${e.honored.name.lowercase()}\",\"group\":\"${e.group.name.lowercase()}\"," +
                "\"requires\":${e.requires?.let { "\"$it\"" } ?: "null"},\"source\":\"${esc(e.source)}\"}"
        } + "],\"capabilities\":{" + capabilities.entries.joinToString(",") { "\"${it.key}\":${it.value}" } + "}}"

    /** Built-ins → pushed JSON, so "Push catalog from watchkit" and a hand-written file agree.
     *  Wrapped as a full object because that is what [parse] reads and what watchkit returns. */
    fun builtinJson(): String =
        "{\"commands\":[" + SlashCommands.BUILTIN.joinToString(",") { e ->
            "{\"name\":\"${e.name}\",\"args\":\"${esc(e.argsHint)}\",\"desc\":\"${esc(e.help)}\"," +
                "\"honored\":\"${e.honored.name.lowercase()}\",\"group\":\"${e.group.name.lowercase()}\"," +
                "\"requires\":${e.requires?.let { "\"$it\"" } ?: "null"}}"
        } + "]"

    /**
     * Overlay rows: built-ins ⊕ whatever watchkit pushed for this gateway (a duplicate name means
     * the gateway knows better than my curated list — it is reading the live `/v1/capabilities`).
     * An agent's SKILLS arrive as ordinary rows here (`honored:"skill"`, `group:"skills"`), because
     * watchkit is the one that can read `GET /v1/skills` without a profile key (SPEC §12.3); the
     * watch never needs a skills endpoint of its own.
     *
     * Order within a group is the caller's job (recents first, then frequency, then A–Z); this only
     * decides membership + capability dimming.
     */
    fun merge(builtins: List<CommandEntry>, gateway: List<CommandEntry>): List<CommandEntry> {
        val out = LinkedHashMap<String, CommandEntry>()
        for (e in builtins + gateway) out[e.name] = e
        return out.values.toList()
    }

    private fun esc(s: String): String = s.replace("\\", "\\\\").replace("\"", "'")
}

/** Parsed catalog: overlay rows + the capability flags the overlay dims by. */
data class Catalog(
    val entries: List<CommandEntry> = emptyList(),
    val capabilities: Map<String, Boolean> = emptyMap(),
) {
    companion object { val EMPTY = Catalog() }
}
