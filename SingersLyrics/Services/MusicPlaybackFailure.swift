import Foundation
#if os(iOS)
import MediaPlayer
#endif

/// Only fixed categories and numeric error codes cross the playback boundary.
/// Apple's error descriptions and userInfo may contain account data or tokens.
struct MusicPlaybackFailure: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case invalidLink, appAuthorization, signIn, accountSetup, accountAccess
        case subscriptionAccess, songUnavailable, catalogAccess, network, service, request
    }

    enum Stage: String, Equatable, Sendable {
        case authorization, subscription, catalog, playback, resume, seek
    }

    let reason: Reason
    let stage: Stage
    let code: String

    var title: String {
        switch reason {
        case .invalidLink: "Check the Song Link"
        case .appAuthorization: "Media Library Access Failed"
        case .signIn: "Sign In to Apple Music"
        case .accountSetup: "Finish Apple Music Setup"
        case .accountAccess: "Apple Music Account Access Failed"
        case .subscriptionAccess: "Catalog Playback Is Unavailable"
        case .songUnavailable: "Song Not Available"
        case .catalogAccess: "Apple Music Access Was Rejected"
        case .network: "Could Not Connect to Apple Music"
        case .service: "Apple Music Is Temporarily Unavailable"
        case .request: "Apple Music Request Failed"
        }
    }

    var message: String {
        switch reason {
        case .invalidLink:
            "Replace the song’s Apple Music link with a link shared from the Music app."
        case .appAuthorization:
            "Allow this app to access Media & Apple Music in Settings, then try again."
        case .signIn:
            "Open the Music app and sign in to the account with Apple Music access, then try again."
        case .accountSetup:
            "Open the Music app and complete any account, privacy, or updated-terms prompts, then try again."
        case .accountAccess:
            "Apple could not authorize access to your music account. Open the Music app, confirm that the song plays there, then try again here."
        case .subscriptionAccess:
            "Apple reports that this device’s music account cannot currently play catalog songs. Open the Music app and verify playback with the account that has your subscription."
        case .songUnavailable:
            "The linked song is unavailable in this account’s Apple Music catalog. Find the song in the Music app and replace its link in Song Options."
        case .catalogAccess:
            "Apple rejected access to its music catalog. Confirm that the Music app can play the song, then try again."
        case .network:
            "The request to Apple Music could not connect or timed out. Try again once the connection is available."
        case .service:
            "Apple’s music service could not complete the request. Wait a moment, then try again."
        case .request:
            "Apple Music could not complete the request. Try playing the song in the Music app. The technical details below identify the failed step without including account or song information."
        }
    }

    var diagnostic: String { "\(stage.rawValue): \(code)" }
}

#if os(iOS)
extension MusicPlaybackFailure {
    static func classify(_ error: any Error, stage: Stage) -> Self {
        // Follow only the standard underlying-error chain. Never surface error
        // descriptions, arbitrary domains, or userInfo values.
        var cause: any Error = error
        for _ in 0..<5 {
            let cocoa = cause as NSError
            if cocoa.domain == NSURLErrorDomain {
                return Self(reason: .network, stage: stage, code: "NSURLErrorDomain \(cocoa.code)")
            }
            if cocoa.domain == MPErrorDomain {
                let reason: Reason = switch cocoa.code {
                // The controller reports denied device permission separately;
                // an authorized app can also receive a service access denial.
                case 1: .accountAccess
                case 2: .subscriptionAccess
                case 3, 7: .network
                case 4: .songUnavailable
                case 5, 6: .request
                default: .request
                }
                return Self(reason: reason, stage: stage, code: "MPErrorDomain \(cocoa.code)")
            }
            guard let underlying = cocoa.userInfo[NSUnderlyingErrorKey] as? any Error else { break }
            cause = underlying
        }
        let cocoa = cause as NSError
        let publicDomains: Set<String> = [
            NSCocoaErrorDomain, NSOSStatusErrorDomain, NSPOSIXErrorDomain,
        ]
        let domain = publicDomains.contains(cocoa.domain) ? cocoa.domain : "AppleMusicError"
        return Self(reason: .request, stage: stage, code: "\(domain) \(cocoa.code)")
    }
}
#endif
