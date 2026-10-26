package dev.hermes.wearos.domain

import dev.hermes.wearos.Screen

/**
 * THE BACK BUTTON RING (owner batch 6: *"chat to sessions to agents, but instead of quit at
 * agents, let's go back to chat again — the app shouldn't really quit unless I hit the home
 * button, that way we stay in Hermes"*). Physical back walks the three core surfaces in a loop:
 * **Chat → Sessions → Agents → Chat → …**. Keyboard/sheets/pickers always unwind first — that
 * stays the topmost-layer cascade in MainActivity; the ring only answers when nothing is open.
 * No hidden state: one pure function of where you are. Chats/Settings rejoin the ring at its
 * hub (Chat), and no action here ever finishes the activity — leaving is the home button's job.
 * No android imports — unit-tested.
 */
object BackRing {

    enum class Action { ToSessions, ToAgents, ToChat }

    fun action(screen: Screen): Action = when (screen) {
        Screen.Chat -> Action.ToSessions
        Screen.Sessions -> Action.ToAgents // the picker overlay opens; its back closes onto Chat
        else -> Action.ToChat
    }
}
