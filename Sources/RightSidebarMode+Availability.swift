import Foundation

extension RightSidebarMode {
    static func from(cliArgument rawValue: String) -> RightSidebarMode? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "files":
            return .files
        case "find":
            return .find
        case "sourcecontrol", "source-control", "git", "scm":
            return .sourceControl
        case "vault", "sessions":
            return .sessions
        case "feed":
            return .feed
        case "dock":
            return .dock
        default:
            return nil
        }
    }

    static func availableModes(defaults: UserDefaults = .standard) -> [RightSidebarMode] {
        availableModes(
            feedEnabled: RightSidebarBetaFeatureSettings.isFeedEnabled(defaults: defaults),
            dockEnabled: RightSidebarBetaFeatureSettings.isDockEnabled(defaults: defaults),
            defaults: defaults
        )
    }

    static func availableModes(
        feedEnabled: Bool,
        dockEnabled: Bool,
        defaults: UserDefaults = .standard
    ) -> [RightSidebarMode] {
        allCases.filter {
            $0.isAvailable(feedEnabled: feedEnabled, dockEnabled: dockEnabled, defaults: defaults)
        }
    }

    func isAvailable(defaults: UserDefaults = .standard) -> Bool {
        isAvailable(
            feedEnabled: RightSidebarBetaFeatureSettings.isFeedEnabled(defaults: defaults),
            dockEnabled: RightSidebarBetaFeatureSettings.isDockEnabled(defaults: defaults),
            defaults: defaults
        )
    }

    func isAvailable(feedEnabled: Bool, dockEnabled: Bool, defaults: UserDefaults = .standard) -> Bool {
        guard isEnabledByBetaGate(feedEnabled: feedEnabled, dockEnabled: dockEnabled) else { return false }
        return RightSidebarTabVisibilitySettings.isVisible(self, defaults: defaults)
    }

    /// Whether the tab is unlocked by beta flags, ignoring user visibility.
    private func isEnabledByBetaGate(feedEnabled: Bool, dockEnabled: Bool) -> Bool {
        switch self {
        case .files, .find, .sourceControl, .sessions:
            return true
        case .feed:
            return feedEnabled
        case .dock:
            return dockEnabled
        }
    }
}
