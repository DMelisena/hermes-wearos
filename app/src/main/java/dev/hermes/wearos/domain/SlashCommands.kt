package dev.hermes.wearos.domain

/**
 * THE SLASH OVERLAY'S CATALOG (owner batch 3: "drag straight down … pop up with an overlay of all
 * the slash commands … I like to use the slash BTW and the slash steer a lot"). What makes this
 * honest rather than a decorative command list is `honored` (SPEC §12.3): the Runs API does **not**
 * dispatch slash commands — `POST /v1/runs` turns `input` into a user message for the MODEL, so a
 * `/steer`-style command posted as text would just ask the model a question that starts with a
 * slash. Every row therefore declares HOW the watch performs it.
 *
 * Rows come from three places, merged in `CommandCatalog`: the curated built-ins below, whatever
 * watchkit's `GET /catalog` knows about the connected gateway (it can read `GET /v1/capabilities`
 * and `GET /v1/skills` where the watch cannot), and `Skill` rows refreshed by `ChatSession` — an
 * agent's skills are slash-invocable (`/<skill>` = that skill's prompt).
 */
data class CommandEntry(
    val name: String,
    val argsHint: String = "",
    /** Short description, shown in the row; gateway-supplied when available. */
    val help: String = "",
    /** Which action the watch performs for this entry. */
    val honored: CommandKind = CommandKind.Prompt,
    /** Overlay section this entry defaults to. */
    val group: CommandGroup = CommandGroup.Commands,
    /** Gateway feature gate from `/v1/capabilities` (null = no gate); unavailable rows dim, never vanish. */
    val requires: String? = null,
    /** Skills carry their agent's source label so provenance is visible. */
    val source: String = "",
) {
    /** "/model <provider:model>" — what gets typed when the row is chosen. */
    val invocation: String get() = if (argsHint.isEmpty()) "/$name" else "/$name $argsHint"
}

/** How the watch honors an entry (SPEC §12.3). `Prompt` is the honest bucket for CLI-only
 *  commands: they go to the model AS TEXT and the model answers about them — no silent 404. */
enum class CommandKind {
    None,
    Steer,        // POST /v1/runs/{id}/steer into the run in flight
    Stop,         // POST /v1/runs/{id}/stop
    Fork,         // POST /api/sessions/{id}/fork — branch from here
    Side,         // /btw: fork, ask in the fork, come back (keeps the main thread clean)
    Model,        // provider/model picker → POST /api/sessions/{id}/model
    Skill,        // run a skill by name (its prompt as a message)
    Client,       // watch-side action (new chat, open sessions/chats/agents/settings…)
    Prompt,       // send the invocation as a prompt (CLI-only commands land here)
    Status,       // client-side gateway/sessions meta summary
}

enum class CommandGroup { Recents, Commands, Skills, Client }

/**
 * The curated built-ins: everything from `GATEWAY_KNOWN_COMMANDS` that a watch can actually DO
 * something with, plus the watch-native ones. `/help` and friends are absent on purpose — they are
 * prompts, and the overlay's search field sends any unmatched text as a prompt anyway.
 */
object SlashCommands {
    val BUILTIN: List<CommandEntry> = listOf(
        CommandEntry("steer", "your guidance", "inject guidance into the run in flight", CommandKind.Steer, CommandGroup.Commands, "run_steer"),
        CommandEntry("stop", "", "stop the run in flight", CommandKind.Stop, CommandGroup.Commands, "run_stop"),
        CommandEntry("btw", "aside", "side conversation in a fork — keeps this thread clean", CommandKind.Side, CommandGroup.Commands, "session_fork"),
        CommandEntry("fork", "", "branch this session and continue there", CommandKind.Fork, CommandGroup.Commands, "session_fork"),
        CommandEntry("model", "", "change the model for this session", CommandKind.Model, CommandGroup.Commands, "model_options"),
        CommandEntry("compact", "", "compress context (asked as a prompt — the gateway decides)", CommandKind.Prompt, CommandGroup.Commands),
        CommandEntry("sessions", "", "gateway/computer sessions", CommandKind.Client, CommandGroup.Client),
        CommandEntry("chats", "", "local chats for this agent", CommandKind.Client, CommandGroup.Client),
        CommandEntry("agents", "", "switch agent", CommandKind.Client, CommandGroup.Client),
        CommandEntry("skills", "", "list this agent's skills", CommandKind.Client, CommandGroup.Client, "skills_api"),
        CommandEntry("new", "", "start a fresh chat", CommandKind.Client, CommandGroup.Client),
        CommandEntry("settings", "", "settings", CommandKind.Client, CommandGroup.Client),
        CommandEntry("health", "", "gateway + watchkit health, right now", CommandKind.Status, CommandGroup.Client),
    )

    // A bare "/" counts: it is the wrist saying "just show me the list".
    private val NAME_RE = Regex("^/[a-z0-9][a-z0-9_-]*$|^/$")

    /**
     * Does this draft read like a BARE slash word (so hitting send should open the OVERLAY rather
     * than ask)? Once there are args the command is already complete — sending it routes through
     * the catalog (`submitMaybeSlash`), which is what "steer with words typed" has to do.
     */
    fun looksLikeSlashDraft(text: String): Boolean {
        val head = text.trim().lineSequence().firstOrNull()?.trim() ?: return false
        if (!head.startsWith("/") || head.contains(' ')) return false
        return NAME_RE.matches(head)
    }

    /**
     * Overlay filter: prefix matches first (`/st` → /stack-chain-like prefixes), substring
     * matches next, never a name-only world — description text is searchable too. Blank query =
     * everything, in the caller's order.
     */
    fun matches(query: String, entries: List<CommandEntry>): List<CommandEntry> {
        val q = query.trim().lowercase().removePrefix("/")
        if (q.isEmpty()) return entries
        val prefix = mutableListOf<CommandEntry>()
        val contains = mutableListOf<CommandEntry>()
        for (e in entries) {
            val name = e.name.lowercase()
            when {
                name.startsWith(q) -> prefix.add(e)
                name.contains(q) || e.help.lowercase().contains(q) -> contains.add(e)
            }
        }
        return prefix + contains
    }

    /**
     * How many SKILL rows a blank filter shows. A watch face is not a 200-row menu: this agent
     * carries 184 skills, and the ⌘ lane exists first for the actions the owner actually takes —
     * skills are the thing you SEARCH for by name, so browsing shows a preview and typing shows
     * everything. (watchkit caps the payload too; the hint row keeps the two honest.)
     */
    const val SKILL_PREVIEW = 12

    /** Skill rows for the overlay section: all of them while filtering, a preview while browsing. */
    fun skillSection(rows: List<CommandEntry>, query: String): List<CommandEntry> =
        if (query.trim().isNotEmpty()) rows else rows.take(SKILL_PREVIEW)
}
