package dev.hermes.wearos.domain

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import dev.hermes.wearos.net.HermesApi

/**
 * THE MODEL PICKER CATALOG (owner: *"instead of the notes lane … make that the model selector …
 * only models that are enabled within the gateway should be shown"*).
 *
 * Wire shape (GET /api/model/options, verified live against Hermes 0.21.7):
 * `{model, provider, providers:[{slug, name, authenticated, is_current, total_models,
 *   models:[…ids], featured_models:[…ids]}]}`. Top-level `model`/`provider` = the gateway's
 * configured DEFAULT — what new sessions ride when nothing is picked.
 *
 * "Enabled" is the dashboard rule: the provider is AUTHENTICATED and actually LISTS models.
 * An unauthenticated provider (no key/OAuth on the box) can't serve anything, so it is not a
 * choice the wrist should ever see. Models are what the picker lists; `provider` is carried per
 * group so a future lock/`provider/model` payload never has to guess.
 *
 * Pure parse + a tiny process-lifetime cache (the options endpoint may enrich with provider
 * catalog fetches server-side — refetching on every dial spin would be rude). JVM-tested.
 *
 * There is deliberately NO endpoint/key editing anywhere in this flow: the owner's rule is
 * "endpoint editing should be done in the gateway" — the watch only picks from what answers.
 */
object ModelCatalog {

    data class Group(
        val provider: String,          // slug, e.g. "openrouter"
        val name: String,              // display name, e.g. "OpenRouter"
        val models: List<String>,      // model ids, featured-first as the gateway orders them
        val isCurrent: Boolean,        // the provider the gateway default rides on
    )

    data class Catalog(
        val defaultModel: String,      // gateway configured default ("" = unknown)
        val defaultProvider: String,
        val groups: List<Group>,       // enabled providers, current-provider first, then gateway order
    ) {
        /** Every model id in the catalog (deduped, provider-prefixed ids stay as-is). */
        fun allModels(): List<String> = groups.flatMap { it.models }.distinct()
    }

    /** Parse the /api/model/options payload. Malformed input yields an empty catalog (fail-soft). */
    fun parse(root: JsonObject): Catalog {
        val arr = root["providers"] as? JsonArray ?: return Catalog("", "", emptyList())
        fun JsonObject.str(key: String): String? =
            (this[key] as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotEmpty() }
        val groups = arr.mapNotNull { el ->
            val p = el as? JsonObject ?: return@mapNotNull null
            val authed = (p["authenticated"] as? JsonPrimitive)?.let { it.content == "true" } ?: false
            val models = (p["models"] as? JsonArray)
                ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull?.takeIf { m -> m.isNotBlank() } }
                ?: emptyList()
            if (!authed || models.isEmpty()) return@mapNotNull null
            Group(
                provider = p.str("slug") ?: return@mapNotNull null,
                name = p.str("name") ?: p.str("slug") ?: "provider",
                models = models.distinct(),
                isCurrent = (p["is_current"] as? JsonPrimitive)?.let { it.content == "true" } ?: false,
            )
        }
        val current = groups.firstOrNull { it.isCurrent }
        return Catalog(
            defaultModel = root.str("model") ?: "",
            defaultProvider = root.str("provider") ?: "",
            groups = if (current == null) groups else listOf(current) + groups.filter { it !== current },
        )
    }

    // ---- process cache: the dial can be spun often; the catalog changes ~never mid-drive ----
    private const val TTL_MS = 3 * 60_000L
    private val lock = Any()
    private var cachedBase: String = ""
    private var cachedAt = 0L
    private var cached: Catalog? = null

    /** Cached fetch: fresh within [TTL_MS] for the SAME base URL, otherwise one flight. */
    fun load(api: dev.hermes.wearos.net.HermesApi, force: Boolean = false): Catalog = synchronized(lock) {
        val now = System.currentTimeMillis()
        cached?.let {
            if (!force && cachedBase == api.baseUrl && now - cachedAt < TTL_MS) return it
        }
        val fresh = api.modelOptions()
        cached = fresh; cachedBase = api.baseUrl; cachedAt = now
        fresh
    }

    /** Drop the cache (agent/gateway switch — the catalog is per-profile, per-endpoint). */
    fun invalidate() = synchronized(lock) { cached = null; cachedBase = "" }

    /** A model id is display-safe truncated: `anthropic/claude-opus-5.5` → `claude-opus-5.5` tail kept. */
    fun shortName(model: String): String = model.substringAfterLast('/').take(28)
}
