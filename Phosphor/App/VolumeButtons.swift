import SwiftUI
import UIKit
import AVFoundation
import MediaPlayer

/// Turns the iPhone's side volume buttons into volume buttons for the TV / sound bar while the app is open.
/// Each press nudges the phone's volume; we read the nudge, send it on as steps, and put the phone's volume
/// straight back. A hidden MPVolumeView keeps iOS from showing its own volume overlay.
@MainActor
final class VolumeButtons {
    static let shared = VolumeButtons()

    /// Called with +n / -n steps (presses that came in together are added up).
    var onStep: ((Int) -> Void)?
    /// When this says no (device known to be off), presses go to the phone as normal.
    var shouldIntercept: () -> Bool = { true }

    private(set) var active = false
    private var observation: NSKeyValueObservation?
    private var pivot: Float = 0.5
    private var original: Float?
    private var resetting = false
    private var pending = 0
    private var flush: Task<Void, Never>?
    private static let step: Float = 1.0 / 16.0

    let volumeView: MPVolumeView = {
        let v = MPVolumeView(frame: CGRect(x: -3000, y: -3000, width: 1, height: 1))
        v.alpha = 0.01
        v.isUserInteractionEnabled = false
        return v
    }()

    private var slider: UISlider? { volumeView.subviews.lazy.compactMap { $0 as? UISlider }.first }

    func start() {
        guard !active else { return }
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.ambient, options: [.mixWithOthers])
            try s.setActive(true)
        } catch {
            return
        }
        active = true
        original = s.outputVolume
        pivot = Self.clampPivot(s.outputVolume)
        if pivot != s.outputVolume { set(pivot) }
        observation = s.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let v = change.newValue else { return }
            Task { @MainActor in self?.changed(v) }
        }
    }

    func stop() {
        guard active else { return }
        observation?.invalidate()
        observation = nil
        flush?.cancel()
        if pending != 0 { onStep?(pending); pending = 0 }
        if let original { set(original) }
        active = false
        // Give the slider a moment to apply before letting go of the session.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    /// Keeps the pivot off the ends so a press either way always registers.
    private static func clampPivot(_ v: Float) -> Float { min(max(v, step * 1.5), 1 - step * 1.5) }

    private func changed(_ v: Float) {
        if resetting {
            if abs(v - pivot) < 0.01 { resetting = false }
            return
        }
        let delta = v - pivot
        guard abs(delta) > 0.01 else { return }
        guard shouldIntercept() else {
            // Let the phone have it: this is now the phone's real volume.
            original = v
            pivot = Self.clampPivot(v)
            if pivot != v { set(pivot) }
            return
        }
        var steps = Int((delta / Self.step).rounded())
        if steps == 0 { steps = delta > 0 ? 1 : -1 }
        pending += steps
        set(pivot)
        flush?.cancel()
        flush = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled, self.pending != 0 else { return }
            let n = self.pending
            self.pending = 0
            self.onStep?(n)
        }
    }

    private func set(_ v: Float) {
        resetting = true
        let s = slider
        Task { @MainActor in
            s?.value = v
            s?.sendActions(for: .valueChanged)
        }
        // If the change never comes back (already there), don't stay deaf.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self?.resetting = false
        }
    }
}

/// Put this somewhere in the view tree: it hosts the hidden MPVolumeView that hides iOS's volume overlay.
struct VolumeHUDHider: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let host = UIView(frame: .zero)
        host.isUserInteractionEnabled = false
        host.addSubview(VolumeButtons.shared.volumeView)
        return host
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
