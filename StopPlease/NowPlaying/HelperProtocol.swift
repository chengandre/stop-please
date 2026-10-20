import Foundation

/// How the app recognizes one Now Playing source later. Neither part is enough
/// alone: process IDs get reused, and ad-hoc Electron apps share the client
/// bundle "Electron".
struct SourceID: Hashable, Codable, Sendable {
    let pid: Int32
    let clientBundle: String
}

/// One source in the helper's `list` reply, e.g.
///
///     {"pid": 1332, "clientBundle": "Electron",
///      "appBundle": "com.github.th-ch.youtube-music", "appName": "YouTube Music",
///      "state": "Paused", "title": "…"}
///
/// Everything except `pid` and `clientBundle` is for display only.
struct Source: Decodable, Sendable {
    let pid: Int32
    /// Null when MediaRemote reports no bundle; such a source cannot be commanded.
    let clientBundle: String?
    let appBundle: String?
    let appName: String?
    /// MediaRemote's name for the state: "Playing", "Paused", or another state.
    let state: String
    let title: String?

    var id: SourceID? { clientBundle.map { SourceID(pid: pid, clientBundle: $0) } }
}

/// The helper's `list` reply.
struct NowPlayingList: Sendable {
    let sources: [Source]
    /// The system's current Now Playing source, where the Play/Pause key goes. Nil
    /// when there is none, or when it has no client bundle and cannot be commanded.
    let current: SourceID?
}

enum CommandAction: String, Encodable, Sendable {
    case play, pause
}

/// One target's result in a `command` reply, e.g.
///
///     {"pid": 1334, "outcome": "done", "route": "override", "state": "Paused"}
///
/// `route` is not decoded: whether anything was sent follows from `outcome` alone
/// (BUILD_GUIDE §3.2).
struct TargetResult: Decodable, Sendable {
    enum Outcome: String, Decodable, Sendable {
        case done, skipped, notFound, ambiguousBundle, overrideNotHonored, noStateChange
    }

    let outcome: Outcome
    /// The last state MediaRemote reported for the target, when one was read.
    let state: String?
}
