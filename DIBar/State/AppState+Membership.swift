import Foundation
import os

private let log = Logger(subsystem: "com.dibar", category: "AppState")

/// Membership and subscription gating.
extension AppState {
    /// Subscriptions are account-level and managed on DI's site — the sibling
    /// domains have no subscription page of their own.
    static let subscriptionURL = URL(string: "https://www.di.fm/member/subscription")!
    var subscriptionURL: URL { Self.subscriptionURL }

    /// Subscription for the selected network, falling back to any active
    /// subscription — in practice one premium subscription streams every
    /// AudioAddict network (verified against the live listen servers).
    var membershipSubscription: MembershipSubscription? {
        subscription(for: selectedNetwork) ?? activeSubscription
    }

    var activeSubscription: MembershipSubscription? {
        subscriptions.first { ($0.status?.lowercased() ?? "") == "active" || $0.trial == true }
    }

    /// True once we have real subscription data to gate against.
    var knowsSubscriptions: Bool { !subscriptions.isEmpty }

    func subscription(for network: Network) -> MembershipSubscription? {
        subscriptions.first { sub in
            // Older responses may omit network_id; treat those as DI since we authenticate against DI.
            let subNetwork = sub.networkId.flatMap(Network.from(networkId:)) ?? .di
            guard subNetwork == network else { return false }
            let status = sub.status?.lowercased() ?? ""
            return status == "active" || status == "trial" || sub.trial == true
        }
    }

    /// True when a playback failure is plausibly a missing-premium problem:
    /// we know the account's subscriptions and none of them is active.
    var playbackFailureLooksLikeNoPremium: Bool {
        knowsSubscriptions && activeSubscription == nil
    }

    var membershipHeaderLine: String {
        guard let status = membershipSubscription?.status?.capitalized, !status.isEmpty else {
            return "Membership"
        }
        return "Membership (\(status))"
    }

    var membershipDetailLine: String {
        guard let subscription = membershipSubscription else {
            if knowsSubscriptions {
                return "No active subscription — tap to subscribe"
            }
            return "Tap to manage subscription"
        }

        var parts: [String] = []
        if let startedAt = subscription.startedDate {
            parts.append("Started \(Self.readableDateFormatter.string(from: startedAt))")
        }
        if let expiresOn = subscription.expiresOnDate {
            let prefix = (subscription.autoRenew ?? false) ? "Renews" : "Expires"
            parts.append("\(prefix) \(Self.readableDateFormatter.string(from: expiresOn))")
        }
        if parts.isEmpty {
            return "Tap to manage subscription"
        }
        return parts.joined(separator: " • ")
    }

    func loadMembership() async {
        guard let ak = apiKey else {
            subscriptions = []
            return
        }

        do {
            let profile = try await DIClient.fetchMembership(apiKey: ak)
            subscriptions = profile.subscriptions ?? []
            if let resolvedMemberId = profile.resolvedMemberId, resolvedMemberId != memberId {
                memberId = resolvedMemberId
                Prefs.set(resolvedMemberId, for: .memberId)
            }
            // Log real network_ids so the Network.networkId mapping can be verified in Console
            let summary = subscriptions
                .map { "network_id=\($0.networkId?.description ?? "nil") status=\($0.status ?? "?")" }
                .joined(separator: "; ")
            log.info("loadMembership: \(self.subscriptions.count) subscriptions [\(summary, privacy: .public)]")
        } catch {
            log.error("loadMembership error: \(error.localizedDescription)")
        }
    }

    private static let readableDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
