//
//  Haptics.swift
//  AemiUI
//
//  Unified haptic feedback vocabulary, modeled on Glassware's GlassHaptics.
//

import SwiftUI

// MARK: - Semantic Events

/// Semantic events a component can emit through the Taptic Engine.
///
/// Components emit events at meaningful interaction moments; the active
/// ``HapticsConfiguration`` maps each event to a concrete `SensoryFeedback`.
/// Consumers override the mapping through the `haptics(_:)` environment
/// modifier instead of touching components.
public enum HapticEvent: Sendable, Equatable, CaseIterable {
    /// A discrete value moved to a new index — picker, stepper, segmented
    /// control. Apple's HIG canonical mapping is `.selection`.
    case selectionChange

    /// User pushed against a min/max — slider clamp, rubber-band end.
    case boundaryReached

    /// A two-state control flipped on.
    case toggleOn

    /// A two-state control flipped off.
    case toggleOff

    /// A value was committed — drag released onto a snap, slider lift-off.
    case commit

    /// Terminal warning (validation, almost-out-of-range).
    case warning

    /// Terminal error (rejected input, blocked action).
    case error

    /// Terminal success (apply, save, paid).
    case success
}

extension HapticEvent {
    /// Outcome events still fire under Low Power Mode because they
    /// double as accessibility cues for blocked / completed actions.
    var isOutcome: Bool {
        switch self {
        case .warning, .error, .success: true
        case .selectionChange, .boundaryReached, .toggleOn, .toggleOff, .commit: false
        }
    }
}

// MARK: - Configuration

/// Mapping from ``HapticEvent`` to `SensoryFeedback` plus a few system-level
/// gates. The default `.standard` follows Apple HIG: light selection clicks
/// for discrete movement, light/medium impacts for state changes and commits,
/// and the system semantic effects for warning / error / success.
public struct HapticsConfiguration: Sendable, Equatable {
    /// Master enable. When false, components emit nothing.
    public var isEnabled: Bool

    /// When true (default), non-outcome events are suppressed while
    /// `ProcessInfo.processInfo.isLowPowerModeEnabled` is on. Outcome events
    /// (success / warning / error) still fire because they aid accessibility.
    public var suppressUnderLowPower: Bool

    public var selectionChange: SensoryFeedback?
    public var boundaryReached: SensoryFeedback?
    public var toggleOn: SensoryFeedback?
    public var toggleOff: SensoryFeedback?
    public var commit: SensoryFeedback?
    public var warning: SensoryFeedback?
    public var error: SensoryFeedback?
    public var success: SensoryFeedback?

    /// Creates a haptics configuration with optional per-event overrides.
    /// All parameters have HIG-aligned defaults — override only the events
    /// whose feel you want to change; pass `nil` for an event to silence it.
    public init(
        isEnabled: Bool = true,
        suppressUnderLowPower: Bool = true,
        selectionChange: SensoryFeedback? = .selection,
        boundaryReached: SensoryFeedback? = .impact(weight: .light, intensity: 0.6),
        toggleOn: SensoryFeedback? = .impact(weight: .light),
        toggleOff: SensoryFeedback? = .impact(weight: .light),
        commit: SensoryFeedback? = .impact(weight: .medium, intensity: 0.7),
        warning: SensoryFeedback? = .warning,
        error: SensoryFeedback? = .error,
        success: SensoryFeedback? = .success
    ) {
        self.isEnabled = isEnabled
        self.suppressUnderLowPower = suppressUnderLowPower
        self.selectionChange = selectionChange
        self.boundaryReached = boundaryReached
        self.toggleOn = toggleOn
        self.toggleOff = toggleOff
        self.commit = commit
        self.warning = warning
        self.error = error
        self.success = success
    }

    /// Default HIG-aligned vocabulary.
    public static let standard = HapticsConfiguration()

    /// Fully silent.
    public static let disabled = HapticsConfiguration(isEnabled: false)

    /// Resolves an event to the feedback that should actually be played, or
    /// `nil` if it should be skipped. Honors `isEnabled` and the Low Power
    /// Mode rule. The system Sounds & Haptics master switch is honored by
    /// `SensoryFeedback` itself.
    func feedback(for event: HapticEvent) -> SensoryFeedback? {
        guard isEnabled else { return nil }
        if suppressUnderLowPower,
           !event.isOutcome,
           ProcessInfo.processInfo.isLowPowerModeEnabled {
            return nil
        }
        return switch event {
        case .selectionChange: selectionChange
        case .boundaryReached: boundaryReached
        case .toggleOn: toggleOn
        case .toggleOff: toggleOff
        case .commit: commit
        case .warning: warning
        case .error: error
        case .success: success
        }
    }
}

// MARK: - Environment

extension EnvironmentValues {
    /// Active haptics configuration for this subtree.
    @Entry public var aemiHaptics: HapticsConfiguration = .standard
}

public extension View {
    /// Override the haptic vocabulary used in this subtree.
    /// Pass `.disabled` to silence haptics entirely.
    func haptics(_ configuration: HapticsConfiguration) -> some View {
        environment(\.aemiHaptics, configuration)
    }

    /// Convenience: toggle haptics on or off without authoring a full
    /// configuration. Preserves any existing custom mapping when re-enabling.
    func haptics(enabled: Bool) -> some View {
        transformEnvironment(\.aemiHaptics) { config in
            config.isEnabled = enabled
        }
    }

    /// Plays the configured `SensoryFeedback` for `event` each time
    /// `trigger` changes, honoring the active ``HapticsConfiguration``.
    func haptic<T: Equatable>(_ event: HapticEvent, trigger: T) -> some View {
        modifier(HapticEmitter(event: event, trigger: trigger))
    }
}

private struct HapticEmitter<T: Equatable>: ViewModifier {
    let event: HapticEvent
    let trigger: T
    @Environment(\.aemiHaptics) private var config

    func body(content: Content) -> some View {
        // The closure form of `.sensoryFeedback` runs on every trigger change
        // and returns the feedback to play (or nil to skip), so the
        // configuration is re-resolved each fire — toggling Low Power Mode or
        // switching configurations mid-session takes effect immediately.
        content.sensoryFeedback(trigger: trigger) { _, _ in
            config.feedback(for: event)
        }
    }
}

// MARK: - Imperative Engine (pre-warmed generators)

#if os(iOS)
import UIKit

/// Imperative counterpart of the `.haptic(_:trigger:)` modifier, for call
/// sites outside a view update (gesture callbacks, model layers).
///
/// Generators are created once and kept warm with `prepare()` so the first
/// fire has no Taptic Engine spin-up latency. Call ``prepare(for:)`` shortly
/// before an interaction begins (e.g. on drag start) for minimal latency.
@MainActor
public enum HapticEngine {
    private static let selection = UISelectionFeedbackGenerator()
    private static let notification = UINotificationFeedbackGenerator()
    private static let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private static let mediumImpact = UIImpactFeedbackGenerator(style: .medium)

    /// Pre-warms the Taptic Engine for the given event.
    public static func prepare(for event: HapticEvent) {
        generator(for: event).prepare()
    }

    /// Plays the feedback for `event`, honoring `configuration`'s gates.
    public static func play(
        _ event: HapticEvent,
        configuration: HapticsConfiguration = .standard
    ) {
        guard configuration.feedback(for: event) != nil else { return }
        switch event {
        case .selectionChange:
            selection.selectionChanged()
        case .boundaryReached:
            lightImpact.impactOccurred(intensity: 0.6)
        case .toggleOn, .toggleOff:
            lightImpact.impactOccurred()
        case .commit:
            mediumImpact.impactOccurred(intensity: 0.7)
        case .warning:
            notification.notificationOccurred(.warning)
        case .error:
            notification.notificationOccurred(.error)
        case .success:
            notification.notificationOccurred(.success)
        }
    }

    private static func generator(for event: HapticEvent) -> UIFeedbackGenerator {
        switch event {
        case .selectionChange: selection
        case .boundaryReached, .toggleOn, .toggleOff: lightImpact
        case .commit: mediumImpact
        case .warning, .error, .success: notification
        }
    }
}
#endif
