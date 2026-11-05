//
//  SubscriptionFeedErrorTests.swift
//  YatteeTests
//
//  Tests for which feed errors the context banner speaks for.
//

import Testing
import Foundation
@testable import Yattee

@Suite("Subscription Feed Error Display")
struct SubscriptionFeedErrorTests {

    // MARK: - Without a banner

    // MARK: - Under the banner

    @Test("An account error stands down under the banner")
    func notAuthenticatedStandsDownUnderBanner() {
        let state = FeedLoadState.error(.notAuthenticated)

        #expect(state.displayedError(contextBannerVisible: true) == nil)
    }

    @Test("A failed refresh keeps its error under the banner")
    func networkErrorSurvivesTheBanner() {
        let state = FeedLoadState.error(.networkError("The Internet connection appears to be offline."))

        #expect(
            state.displayedError(contextBannerVisible: true)
                == .networkError("The Internet connection appears to be offline.")
        )
    }

    // MARK: - Asking again on a timer

    @Test("A network failure keeps trying whatever the context is doing")
    func networkErrorAlwaysRetries() {
        let state = FeedLoadState.error(.networkError("The request timed out."))
        let reasons: [DataContextUnavailability?] = [
            nil, .checking, .instancePending, .instanceDisabled,
            .credentialMissing, .credentialRejected, .unreachable
        ]

        for reason in reasons {
            #expect(state.warrantsPeriodicRetry(unavailability: reason))
        }
    }

    @Test("An account error is not answered by asking the feed again")
    func notAuthenticatedNeverRetries() {
        let state = FeedLoadState.error(.notAuthenticated)

        #expect(!state.warrantsPeriodicRetry(unavailability: .unreachable))
        #expect(!state.warrantsPeriodicRetry(unavailability: .credentialRejected))
        #expect(!state.warrantsPeriodicRetry(unavailability: nil))
    }

    @Test("A feed that is not sitting on an error has nothing to retry")
    func nonErrorStatesNeverRetry() {
        let states: [FeedLoadState] = [
            .idle,
            .loading,
            .loadingMore,
            .ready,
            .partiallyLoaded(readyCount: 1, pendingCount: 2, errorCount: 0)
        ]

        for state in states {
            #expect(!state.warrantsPeriodicRetry(unavailability: nil))
            #expect(!state.warrantsPeriodicRetry(unavailability: .unreachable))
        }
    }

    // MARK: - Other states

    @Test("States that are not errors have nothing to show")
    func nonErrorStatesShowNothing() {
        let states: [FeedLoadState] = [
            .idle,
            .loading,
            .loadingMore,
            .ready,
            .partiallyLoaded(readyCount: 1, pendingCount: 2, errorCount: 0)
        ]

        for state in states {
            #expect(state.displayedError(contextBannerVisible: false) == nil)
            #expect(state.displayedError(contextBannerVisible: true) == nil)
        }
    }
}
