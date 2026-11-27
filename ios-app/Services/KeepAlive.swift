import AVFAudio
import CoreLocation
import Foundation
import UIKit

/// Keeps the app running in the background with silent audio (and optional
/// background location updates) so location simulation survives switching
/// to the 7-Eleven app. Mirrors SideInstaller's `KeepAlive`.
@MainActor
final class KeepAlive: NSObject {

    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var audioRunning = false
    private var interrupted = false
    private var observers: [NSObjectProtocol] = []
    private var retry: Task<Void, Never>?
    private var logHandler: ((String) -> Void)?

    private var locationRunning = false
    private lazy var locationManager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        return manager
    }()

    init(logHandler: ((String) -> Void)? = nil) {
        self.logHandler = logHandler
        super.init()
    }

    var isAudioActive: Bool { audioRunning && !interrupted }

    func startAudio() {
        guard !audioRunning else { return }
        guard play() else {
            Self.releaseSession()
            return
        }
        audioRunning = true
        observeAudio()
    }

    func stopAudio() {
        guard audioRunning else { return }
        audioRunning = false
        interrupted = false
        retry?.cancel()
        retry = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        silence()
        if player.engine != nil { engine.detach(player) }
        Self.releaseSession()
    }

    func startLocation() {
        guard !locationRunning else { return }
        locationRunning = true
        locationManager.requestAlwaysAuthorization()
        if CLLocationManager.locationServicesEnabled() {
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.startUpdatingLocation()
        }
    }

    func stopLocation() {
        guard locationRunning else { return }
        locationManager.stopUpdatingLocation()
        locationManager.allowsBackgroundLocationUpdates = false
        locationRunning = false
    }

    func stopAll() {
        stopAudio()
        stopLocation()
    }

    private func play() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let format = engine.outputNode.inputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { return false }
            if player.engine == nil { engine.attach(player) }
            engine.connect(player, to: engine.mainMixerNode, format: format)

            let frames = AVAudioFrameCount(format.sampleRate)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return false }
            buffer.frameLength = frames

            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            return true
        } catch {
            silence()
            return false
        }
    }

    private func silence() {
        if player.engine != nil { player.stop() }
        engine.stop()
    }

    private var isPlaying: Bool { engine.isRunning && player.isPlaying }

    private func resume(after cause: String, force: Bool = false) {
        guard audioRunning, !interrupted, force || !isPlaying else { return }
        retry?.cancel()
        retry = nil
        if restart(after: cause) { return }
        retry = Task { [weak self] in
            for delay in [0.5, 1.0, 2.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled,
                      self.audioRunning, !self.interrupted, !self.isPlaying else { return }
                if self.restart(after: cause) { return }
            }
            self?.log("Keep-alive: silent audio didn't restart after \(cause). It will retry when 8/12 is reopened.")
        }
    }

    private func restart(after cause: String) -> Bool {
        silence()
        guard play() else { return false }
        log("Keep-alive: silent audio restarted after \(cause).")
        return true
    }

    private func interruptionBegan() {
        guard audioRunning, !interrupted else { return }
        interrupted = true
        retry?.cancel()
        retry = nil
        log("Keep-alive: silent audio interrupted. It restarts when that ends.")
    }

    private func interruptionEnded() {
        let wasInterrupted = interrupted
        interrupted = false
        resume(after: "an interruption", force: wasInterrupted)
    }

    private func mediaServicesReset() {
        guard audioRunning else { return }
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        interrupted = false
        resume(after: "a media services reset", force: true)
    }

    private func observeAudio() {
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ handle: @escaping @MainActor (KeepAlive, Notification) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    handle(self, note)
                }
            })
        }

        observe(AVAudioSession.interruptionNotification) { me, note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            switch type.flatMap(AVAudioSession.InterruptionType.init) {
            case .began: me.interruptionBegan()
            case .ended: me.interruptionEnded()
            default: break
            }
        }

        if #available(iOS 27.0, *) {
            observe(AVAudioSession.didBecomeInactiveNotification) { me, note in
                let context = note.userInfo?[AVAudioSession.deactivationContextKey]
                    as? AVAudioSession.DeactivationContext
                if context?.source != .app { me.interruptionBegan() }
            }
            observe(AVAudioSession.resumptionRecommendationNotification) { me, _ in
                me.interruptionEnded()
            }
        }

        observe(AVAudioSession.routeChangeNotification) { me, note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let described: String
            switch reason.flatMap(AVAudioSession.RouteChangeReason.init) {
            case .newDeviceAvailable: described = "a new audio output connected"
            case .oldDeviceUnavailable: described = "an audio output disconnected"
            default: described = "an audio route change"
            }
            me.resume(after: described)
        }

        observe(.AVAudioEngineConfigurationChange) { me, note in
            guard (note.object as? AVAudioEngine) === me.engine else { return }
            me.resume(after: "the audio output changed")
        }

        observe(AVAudioSession.mediaServicesWereResetNotification) { me, _ in
            me.mediaServicesReset()
        }

        observe(UIApplication.didBecomeActiveNotification) { me, _ in
            me.interrupted = false
            me.resume(after: "8/12 was reopened")
        }
    }

    private func log(_ message: String) {
        logHandler?(message)
    }

    private static func releaseSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        try? session.setCategory(.ambient)
    }
}

extension KeepAlive: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if status == .authorizedAlways || status == .authorizedWhenInUse {
            MainActor.assumeIsolated {
                guard locationRunning else { return }
                manager.allowsBackgroundLocationUpdates = true
                manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
