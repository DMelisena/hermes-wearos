package dev.hermes.wearos.domain

import dev.hermes.wearos.net.HermesApi
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * JVM sanity for the 🧠 picker inventory (SPEC §12.7). The fixture mirrors the LIVE
 * /api/model/options payload shape (verified against Hermes 0.21.7 on the owner's box):
 * two authenticated providers, one unauthenticated with zero models, one authenticated but
 * empty — only the first two may ever reach the wrist.
 */
class ModelCatalogTest {

    private val fixture = """
    {"model":"Qwen3.8-Flash-Next-Uncensored","provider":"sglang","providers":[
      {"slug":"nous","name":"Nous Portal","authenticated":false,"is_current":false,"total_models":0,"models":[]},
      {"slug":"openrouter","name":"OpenRouter","authenticated":true,"is_current":false,"total_models":2,
        "models":["anthropic/claude-opus-5.5","anthropic/claude-fable-5"]},
      {"slug":"sglang","name":"SGLang local","authenticated":true,"is_current":true,"total_models":1,
        "models":["Qwen3.8-Flash-Next-Uncensored"]},
      {"slug":"copilot","name":"GitHub Copilot","authenticated":true,"is_current":false,"total_models":0,"models":[]},
      {"slug":"broken"}
    ]}
    """

    @Test fun `only enabled providers with models survive, current first`() {
        val cat = ModelCatalog.parse(HermesApi.parse(fixture))
        assertEquals(listOf("sglang", "openrouter"), cat.groups.map { it.provider })
        assertEquals(listOf(true, false), cat.groups.map { it.isCurrent })
        assertEquals("Qwen3.8-Flash-Next-Uncensored", cat.defaultModel)
        assertEquals("sglang", cat.defaultProvider)
    }

    @Test fun `models keep gateway order and dedupe within a group`() {
        val cat = ModelCatalog.parse(HermesApi.parse(fixture))
        val or = cat.groups.first { it.provider == "openrouter" }
        assertEquals(listOf("anthropic/claude-opus-5.5", "anthropic/claude-fable-5"), or.models)
        assertEquals(3, cat.allModels().size)
    }

    @Test fun `malformed payloads fail soft to an empty catalog`() {
        assertEquals(emptyList<ModelCatalog.Group>(), ModelCatalog.parse(HermesApi.parse("{}")).groups)
        assertEquals("", ModelCatalog.parse(HermesApi.parse("""{"providers":42}""")).defaultModel)
        assertTrue(ModelCatalog.parse(HermesApi.parse("""{"providers":[]}""")).groups.isEmpty())
    }

    @Test fun `shortName trims provider prefixes for pill rows`() {
        assertEquals("claude-opus-5.5", ModelCatalog.shortName("anthropic/claude-opus-5.5"))
        assertEquals("plainmodel", ModelCatalog.shortName("plainmodel"))
        assertTrue(ModelCatalog.shortName("x".repeat(60)).length <= 28)
    }
}
