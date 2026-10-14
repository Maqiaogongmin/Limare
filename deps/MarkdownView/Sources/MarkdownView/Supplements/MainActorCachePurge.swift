//
//  MainActorCachePurge.swift
//  MarkdownView
//

import Foundation
import LRUCache

/// Caches of rendered text, cleared under memory pressure on the main queue.
///
/// `LRUCache` clears itself on memory pressure from a global queue. A rendered string can
/// hold a Litext `TextLabel.Attachment`, which must be released on the main actor: released
/// from that queue, its run delegate's teardown traps the process (Limare, 2026-10-13, while
/// in the background). These caches opt out of `LRUCache`'s own clearing and are emptied
/// here instead, by one memory-pressure source on the main queue.
@MainActor
enum MainActorCachePurge {
    private static var clears: [() -> Void] = []

    private static let source: DispatchSourceMemoryPressure = {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                for clear in clears { clear() }
            }
        }
        source.resume()
        return source
    }()

    /// A cache bounded by `countLimit` and emptied on memory pressure on the main queue.
    static func cache<Key: Hashable & Sendable, Value>(countLimit: Int) -> LRUCache<Key, Value> {
        let cache = LRUCache<Key, Value>(countLimit: countLimit, clearsOnMemoryPressure: false)
        _ = source
        clears.append { [weak cache] in cache?.removeAll() }
        return cache
    }
}
