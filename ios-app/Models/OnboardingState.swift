import Foundation

/// Models the 4-stage collapsible first-launch onboarding flow.
struct OnboardingState: Equatable {
    enum Step: Int, CaseIterable, Identifiable {
        case localDevVPN = 0
        case pairingFile = 1
        case disclaimer = 2
        case ready = 3

        var id: Int { rawValue }

        var number: Int { rawValue + 1 }

        var title: String {
            switch self {
            case .localDevVPN: return "LocalDevVPN"
            case .pairingFile: return "Pairing File"
            case .disclaimer: return "Risk Disclaimer"
            case .ready: return "Ready to Go"
            }
        }
    }

    var vpnConfirmed: Bool = false
    var vpnSkipped: Bool = false
    var pairingSkipped: Bool = false
    var disclaimerAcknowledged: Bool = false
    var expandedStep: Step = .localDevVPN

    func isStepComplete(_ step: Step, vpnDetected: Bool, pairingExists: Bool) -> Bool {
        switch step {
        case .localDevVPN:
            return vpnDetected || vpnConfirmed || vpnSkipped
        case .pairingFile:
            return pairingExists || pairingSkipped
        case .disclaimer:
            return disclaimerAcknowledged
        case .ready:
            return disclaimerAcknowledged
        }
    }

    func isStepSkipped(_ step: Step, vpnDetected: Bool, pairingExists: Bool) -> Bool {
        switch step {
        case .localDevVPN:
            return !vpnDetected && !vpnConfirmed && vpnSkipped
        case .pairingFile:
            return !pairingExists && pairingSkipped
        case .disclaimer, .ready:
            return false
        }
    }

    var canContinueToApp: Bool {
        disclaimerAcknowledged
    }

    mutating func advance(vpnDetected: Bool, pairingExists: Bool) {
        for step in Step.allCases {
            if !isStepComplete(step, vpnDetected: vpnDetected, pairingExists: pairingExists) {
                expandedStep = step
                return
            }
        }
        expandedStep = .ready
    }

    mutating func confirmVPN() {
        vpnConfirmed = true
        vpnSkipped = false
    }

    mutating func skipVPN() {
        vpnSkipped = true
    }

    mutating func skipPairing() {
        pairingSkipped = true
    }

    mutating func acknowledgeDisclaimer() {
        disclaimerAcknowledged = true
    }
}
