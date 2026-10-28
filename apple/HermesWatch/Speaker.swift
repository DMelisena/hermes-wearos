import AVFoundation

/// Speak-aloud for settled answers (SPEC voice-out, default ON) — on-device synthesis only.
@MainActor
final class Speaker {
    private let synth = AVSpeechSynthesizer()

    func speak(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        synth.stopSpeaking(at: .immediate)
        synth.speak(AVSpeechUtterance(string: String(t.prefix(1_200))))
    }

    func stop() { synth.stopSpeaking(at: .immediate) }
}
