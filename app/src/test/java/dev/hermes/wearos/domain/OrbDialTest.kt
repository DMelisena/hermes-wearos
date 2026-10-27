package dev.hermes.wearos.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.sin

/**
 * THE DIAL TABLE (SPEC §12.1). The owner's watch is numerically identical to the 480 reference
 * (Galaxy Watch Ultra: 480×480 @ 340dpi ⇒ scale 1.0), so every expectation here is a real screen px
 * on the device he reviews this on — the orb center lives where `BottomLayout` puts it, (240, 401).
 *
 * Three things this table has to guarantee: the clock face reads the way he asked (up = keyboard,
 * 1:30 = mute, 3:00 = record, 4:30 = notes, 6:00 = commands, 9:00 = sessions, 10:30 = agents), the
 * wedges own the slop (a diagonal is never ambiguous), and the LOWER three directions only become
 * drawable because the contextual rise moves the disc — which is exactly why the rise exists.
 */
class OrbDialTest {

    private val scale = 1f                       // the owner's 480 face
    private val orbX = 240f
    private val orbY = BottomLayout.geometry(480f, 480f).talk.cy // approved geometry = 401
    private val slots = OrbDial.DEFAULT_SLOTS

    /** A drag vector: [len] px along the clock angle (0 = up, 90 = right, 180 = down). */
    private fun vec(clockDeg: Float, len: Float = 120f): Pair<Float, Float> {
        val rad = Math.toRadians(clockDeg.toDouble())
        return Pair((len * sin(rad)).toFloat(), (-len * cos(rad)).toFloat())
    }

    private fun laneAt(clockDeg: Float, len: Float = 120f): Lane? =
        OrbDial.laneAt(slots, vec(clockDeg, len).first, vec(clockDeg, len).second, scale)

    private fun inFace(x: Float, y: Float, radius: Float = 237f): Boolean =
        hypot(x - 240.0, y - 240.0) <= radius.toDouble()

    // ── the owner's clock face ───────────────────────────────────────────────────────────────

    @Test fun `the default map is the owner's clock face`() {
        assertEquals(
            listOf(
                Lane.Keyboard, Lane.Mute, Lane.RecordHi, Lane.Model,
                Lane.Commands, Lane.Chats, Lane.Sessions, Lane.Agents,
            ),
            slots,
        )
        assertEquals(8, OrbDial.SLOT_COUNT)
        assertEquals(listOf("12:00", "1:30", "3:00", "4:30", "6:00", "7:30", "9:00", "10:30"),
            (0 until OrbDial.SLOT_COUNT).map { OrbDial.clockLabel(it) })
    }

    @Test fun `each clock direction lands on its lane - straight drags`() {
        assertEquals(Lane.Keyboard, laneAt(0f))     // up: the drag-up that already shipped
        assertEquals(Lane.Mute, laneAt(45f))        // 1:30
        assertEquals(Lane.RecordHi, laneAt(90f))    // 3:00
        assertEquals(Lane.Model, laneAt(135f)) // 4:30
        assertEquals(Lane.Commands, laneAt(180f))   // straight down
        assertEquals(Lane.Chats, laneAt(225f))      // 7:30
        assertEquals(Lane.Sessions, laneAt(270f))   // straight left
        assertEquals(Lane.Agents, laneAt(315f))     // 10:30
    }

    @Test fun `wedges own the slop - every direction inside a wedge keeps its lane`() {
        for ((clock, lane) in listOf(
            0f to Lane.Keyboard, 45f to Lane.Mute, 90f to Lane.RecordHi, 135f to Lane.Model,
            180f to Lane.Commands, 225f to Lane.Chats, 270f to Lane.Sessions, 315f to Lane.Agents,
        )) {
            for (off in listOf(-18f, -8f, 8f, 18f)) {
                assertEquals("angle ${clock + off}°", lane, laneAt(clock + off))
            }
        }
    }

    @Test fun `wedge boundaries fall BETWEEN icons, never on one`() {
        assertEquals(Lane.Keyboard, laneAt(22.4f))
        assertEquals(Lane.Mute, laneAt(22.6f))
        assertEquals(Lane.Keyboard, laneAt(337.6f)) // the 10:30/12:00 seam, other side
        assertEquals(Lane.Agents, laneAt(337.4f))
    }

    @Test fun `angles normalize - a hair past straight-down still reads 6 to 00`() {
        // slot 4 IS 6:00 (slot 0 = 12:00, clockwise by 45°).
        assertEquals(4, OrbDial.slotAt(179.9f))
        assertEquals(4, OrbDial.slotAt(-179.9f))
        assertEquals(0, OrbDial.slotAt(359.99f))
        assertEquals(0, OrbDial.slotAt(-0.5f))
    }

    // ── gates: a flick arms, a tap does not, and coming back cancels ─────────────────────────

    @Test fun `the gate is 51 ref px - just inside is no lane, just past is one`() {
        assertNull(OrbDial.laneAt(slots, 0f, -50.5f, scale))
        assertNotNull(OrbDial.laneAt(slots, 0f, -51.5f, scale))
        assertTrue(OrbDial.isCancel(0f, -50.5f, scale))
        assertFalse(OrbDial.isCancel(0f, -51.5f, scale))
    }

    @Test fun `release back inside the gate cancels the whole gesture`() {
        // Drag out to 4:30, reconsider, come back to 10 px: nothing fires (and it is NOT a tap —
        // TalkOrb only reaches the lane path once armed).
        assertFalse(OrbDial.isCancel(0f, -120f, scale))
        assertTrue(OrbDial.isCancel(3f, -8f, scale))
    }

    @Test fun `the gate scales with the face - a 400px viewport gets a proportionally smaller one`() {
        val s = OrbDial.scaleFor(400f) // 400/480 = 0.8333 ⇒ gate = 51 × 0.8333 = 42.5 px
        assertEquals(400f / BottomLayout.REF, s, 0.0001f)
        assertNull(OrbDial.laneAt(slots, 0f, -41f, s))
        assertNotNull(OrbDial.laneAt(slots, 0f, -46f, s))
        assertEquals(0f, OrbDial.scaleFor(0f), 0.0001f)
        assertNull(OrbDial.laneAt(slots, 0f, -999f, 0f)) // unmeasured first frame: never a lane
    }

    // ── the contextual rise (owner's locked geometry answer) ─────────────────────────────────

    @Test fun `only the lower arc asks for the rise`() {
        for (deg in listOf(112.5f, 135f, 160f, 180f, 200f, 225f, 247.5f)) {
            assertTrue("rises at $deg°", OrbDial.needsRise(vec(deg).first, vec(deg).second, scale))
        }
        for (deg in listOf(0f, 45f, 90f, 315f, 270f, 112f, 248f)) {
            assertFalse("no rise at $deg°", OrbDial.needsRise(vec(deg).first, vec(deg).second, scale))
        }
    }

    @Test fun `no rise before the gate - a jitter under the disc never moves the orb`() {
        assertFalse(OrbDial.needsRise(0f, 30f, scale))
    }

    @Test fun `the lower icons are OFF-FACE until the orb rises - the reason the rise exists`() {
        for (slot in listOf(3, 4, 5)) {
            val (x, y) = OrbDial.iconCenter(orbX, orbY, slot, scale)
            assertFalse("slot $slot at y=$y is past the 480 face", inFace(x, y))
        }
        for (slot in listOf(0, 1, 2, 6, 7)) {
            val (x, y) = OrbDial.iconCenter(orbX, orbY, slot, scale)
            assertTrue("slot $slot at ($x,$y) must already be reachable", inFace(x, y))
        }
    }

    @Test fun `rising to face center puts all eight icons on screen`() {
        val cy = OrbDial.risenCenterY(orbY, 480f)
        assertEquals(240f, cy, 0.01f)
        for (slot in 0 until OrbDial.SLOT_COUNT) {
            val (x, y) = OrbDial.iconCenter(orbX, cy, slot, scale)
            assertTrue("slot $slot at ($x,$y)", inFace(x, y, radius = 237f - OrbDial.ICON_R_REF))
        }
        // and it never pushes the disc DOWNWARD if a device already sits it high
        assertEquals(200f, OrbDial.risenCenterY(200f, 480f), 0.01f)
    }

    @Test fun `icon ring is measured from the orb center in the clock order`() {
        val (x0, y0) = OrbDial.iconCenter(orbX, orbY, 0, scale)
        assertEquals(240f, x0, 0.5f); assertEquals(283f, y0, 0.5f)      // 401 − 118 straight up
        val (x2, y2) = OrbDial.iconCenter(orbX, orbY, 2, scale)
        assertEquals(358f, x2, 0.5f); assertEquals(orbY, y2, 0.5f)      // 3:00
        val (x6, y6) = OrbDial.iconCenter(orbX, orbY, 6, scale)
        assertEquals(122f, x6, 0.5f); assertEquals(orbY, y6, 0.5f)      // 9:00
    }

    @Test fun `the ring sits PAST the activation gate - you drag toward an icon you can see`() {
        assertTrue(OrbDial.ICON_RING_REF > OrbDial.ACTIVATE_REF * 2f)
    }

    // ── the saved map ───────────────────────────────────────────────────────────────────────

    @Test fun `map round-trips through the persisted string`() {
        val raw = OrbDial.encode(slots)
        assertEquals("keyboard,mute,record_hi,model,commands,chats,sessions,agents", raw)
        assertEquals(slots, OrbDial.decode(raw))
    }

    @Test fun `owner remap changes only the lane, not the geometry`() {
        val remapped = listOf(
            Lane.Keyboard, Lane.Model, Lane.Agents, Lane.None,
            Lane.Sessions, Lane.Chats, Lane.RecordHi, Lane.Mute,
        )
        assertEquals(Lane.Mute, OrbDial.laneAt(remapped, vec(315f).first, vec(315f).second, scale)) // 10:30 now mutes
        assertEquals(Lane.Agents, OrbDial.laneAt(remapped, vec(90f).first, vec(90f).second, scale)) // 3:00 opens agents
        assertEquals(Lane.None, OrbDial.laneAt(remapped, vec(135f).first, vec(135f).second, scale)) // 4:30 blanked
        assertEquals(remapped, OrbDial.decode(OrbDial.encode(remapped)))
    }

    @Test fun `a blanked lane is chosen by its wedge and honored as no-op by the caller`() {
        val blanked = listOf(Lane.None, Lane.None, Lane.None, Lane.None, Lane.None, Lane.None, Lane.None, Lane.None)
        assertEquals(Lane.None, OrbDial.laneAt(blanked, 0f, -120f, scale))
        // TalkOrb/MainActivity treat Lane.None as "release, nothing happens" — SPEC §12.1.
    }

    @Test fun `garbage in the settings store never blanks the dial`() {
        assertEquals(slots, OrbDial.decode(null))
        assertEquals(slots, OrbDial.decode(""))
        assertEquals(slots, OrbDial.decode("nonsense,not,a,lane"))
        assertEquals(slots, OrbDial.decode(", ,,,,"))
        // A future build that renames a lane: that slot keeps its default, the rest survive.
        val mixed = OrbDial.decode("keyboard,hologram,record_hi")
        assertEquals(Lane.Keyboard, mixed[0])
        assertEquals(Lane.Mute, mixed[1])
        assertEquals(Lane.RecordHi, mixed[2])
        assertEquals(Lane.Model, mixed[3]) // missing tail → defaults, still 8 long
        assertEquals(8, mixed.size)
    }

    @Test fun `slot reads are index-proof in both directions`() {
        assertEquals(Lane.Keyboard, OrbDial.slotFor(slots, 0))
        assertEquals(Lane.Keyboard, OrbDial.slotFor(slots, 8))   // wraps
        assertEquals(Lane.Agents, OrbDial.slotFor(slots, -1))    // wraps backwards
        // A short/odd saved map never crashes and never shifts the wedges: slot 4 is still 6:00's
        // default lane, whatever the store handed us.
        assertEquals(Lane.Commands, OrbDial.slotFor(emptyList(), 4))
    }

    @Test fun `lane ids are stable settings vocabulary`() {
        listOf(
            "none", "keyboard", "mute", "record_hi", "model",
            "commands", "chats", "sessions", "agents",
        ).forEach { assertNotNull(it, Lane.fromId(it)) }
        assertNull(Lane.fromId("teleport"))
        assertNull(Lane.fromId(""))
        // The notes lane is RETIRED vocabulary (SPEC §12.7: 📝 nobody used → 🧠 model selector).
        assertNull(Lane.fromId("voice_notes"))
    }

    @Test fun `a pre-model-save with voice_notes at 430 migrates to the model lane`() {
        // Owners who never touched the dial carry "…,voice_notes,…" in DataStore. Unknown id →
        // that slot takes its DEFAULT, which is now Lane.Model — silent one-lane migration.
        val legacy = OrbDial.decode("keyboard,mute,record_hi,voice_notes,commands,chats,sessions,agents")
        assertEquals(Lane.Model, legacy[3])
        assertEquals(Lane.Keyboard, legacy[0])
        assertEquals(Lane.Agents, legacy[7])
    }

    @Test fun `clock labels survive the wrap`() {
        assertEquals("12:00", OrbDial.clockLabel(0))
        assertEquals("12:00", OrbDial.clockLabel(8))
        assertEquals("4:30", OrbDial.clockLabel(3))
        assertEquals("10:30", OrbDial.clockLabel(7))
        assertEquals("7:30", OrbDial.clockLabel(5))
        assertEquals("10:30", OrbDial.clockLabel(-1)) // -1 wraps to slot 7
    }

    @Test fun `scaleFor matches BottomLayout on the same viewport`() {
        for (v in listOf(480f, 400f, 360f)) {
            assertEquals(BottomLayout.scaleFor(v, v), OrbDial.scaleFor(v), 0.0001f)
        }
    }
}
