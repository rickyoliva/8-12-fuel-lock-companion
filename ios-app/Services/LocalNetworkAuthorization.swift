import dnssd
import Foundation
import Network
import UIKit

/// Triggers the iOS Local Network permission prompt (required by RPPairing) by
/// briefly advertising and browsing a throwaway Bonjour service.
/// Mirrors SideInstaller's `LocalNetworkAuthorization`.
@MainActor
final class LocalNetworkAuthorization {
    private var browser: NWBrowser?
    private var listener: NWListener?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var observers: [NSObjectProtocol] = []

    private var policyDenied = false
    private var pendingDenial: DispatchWorkItem?
    private var awayForAlert = false

    private let probeType = "_stikpairprobe._tcp"
    private let denialGrace: TimeInterval = 2
    private let afterAlertGrace: TimeInterval = 4

    func request(timeout: TimeInterval = 60) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            self.continuation = cont

            let params = NWParameters.tcp
            params.includePeerToPeer = true

            let listener = try? NWListener(using: params)
            listener?.service = NWListener.Service(name: "FuelLockProbe", type: probeType)
            listener?.newConnectionHandler = { $0.cancel() }
            listener?.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    MainActor.assumeIsolated { self?.finish(false) }
                }
            }
            self.listener = listener

            let browser = NWBrowser(for: .bonjour(type: probeType, domain: nil), using: params)
            browser.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.browserChanged(state) }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                if !results.isEmpty {
                    MainActor.assumeIsolated { self?.finish(true) }
                }
            }
            self.browser = browser

            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.appResigned() }
                },
                center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.appActivated() }
                },
            ]

            listener?.start(queue: .main)
            browser.start(queue: .main)

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                MainActor.assumeIsolated { self?.finish(false) }
            }
        }
    }

    private func browserChanged(_ state: NWBrowser.State) {
        switch state {
        case .failed:
            finish(false)
        case let .waiting(error):
            guard case let .dns(code) = error, Int(code) == kDNSServiceErr_PolicyDenied else { return }
            if !policyDenied {
                policyDenied = true
                awayForAlert = false
                scheduleDenial(after: denialGrace)
            }
        case .ready:
            policyDenied = false
            awayForAlert = false
            cancelDenial()
        default:
            break
        }
    }

    private func appResigned() {
        guard policyDenied else { return }
        awayForAlert = true
        cancelDenial()
    }

    private func appActivated() {
        guard policyDenied, awayForAlert else { return }
        awayForAlert = false
        scheduleDenial(after: afterAlertGrace)
    }

    private func scheduleDenial(after delay: TimeInterval) {
        cancelDenial()
        guard UIApplication.shared.applicationState == .active else {
            awayForAlert = true
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.policyDenied else { return }
                self.finish(false)
            }
        }
        pendingDenial = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelDenial() {
        pendingDenial?.cancel()
        pendingDenial = nil
    }

    private func finish(_ authorized: Bool) {
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(returning: authorized)
        cancelDenial()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        browser?.cancel()
        browser = nil
        listener?.cancel()
        listener = nil
    }
}
