import Foundation
import Testing
@testable import ShellHost

@MainActor @Suite struct BookmarkStoreTests {
    private func makeStore(_ box: Sandbox, key: String = BookmarkStore.gameDataKey) -> BookmarkStore {
        BookmarkStore(defaults: box.defaults(Fixtures.orbit), key: key)
    }

    @Test func nothingStoredResolvesToNone() throws {
        let box = try Sandbox()
        let store = makeStore(box)
        #expect(store.resolve() == .none)
        #expect(!store.hasBookmark)
    }

    @Test func storesResolvesAndClears() throws {
        let box = try Sandbox()
        let folder = box.root.appendingPathComponent("Drive/Data", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = makeStore(box)
        #expect(store.store(folder))
        #expect(store.hasBookmark)
        guard case .url(let url) = store.resolve() else { Issue.record("did not resolve"); return }
        #expect(url.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path)
        // A second store over the same suite (a relaunch) resolves it too.
        guard case .url = makeStore(box).resolve() else { Issue.record("did not resolve after relaunch"); return }
        store.clear()
        #expect(store.resolve() == .none)
        #expect(!store.hasBookmark)
    }

    @Test func aMissingFolderIsNotBookmarked() throws {
        let box = try Sandbox()
        let store = makeStore(box)
        #expect(!store.store(box.root.appendingPathComponent("not-there")))
        #expect(!store.hasBookmark)
    }

    @Test func aBookmarkThatDoesNotResolveIsStale() throws {
        let box = try Sandbox()
        box.defaults(Fixtures.orbit).set(Data("not a bookmark".utf8), forKey: BookmarkStore.gameDataKey)
        let store = makeStore(box)
        #expect(store.resolve() == .stale)
        #expect(store.hasBookmark, "the data stays, the player may install the same signature again")
    }

    @Test func dataAndCloudKeepSeparateBookmarks() throws {
        let box = try Sandbox()
        let a = box.root.appendingPathComponent("A", isDirectory: true), b = box.root.appendingPathComponent("B", isDirectory: true)
        for d in [a, b] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let data = makeStore(box), cloud = makeStore(box, key: BookmarkStore.cloudSavesKey)
        #expect(data.store(a) && cloud.store(b))
        data.clear()
        #expect(data.resolve() == .none)
        guard case .url(let url) = cloud.resolve() else { Issue.record("cloud lost"); return }
        #expect(url.lastPathComponent == "B")
        #expect(BookmarkStore.gameDataKey == "pickedDataBookmark" && BookmarkStore.cloudSavesKey == "cloudSavesBookmark")
    }

    @Test func aRelocatedFolderStillResolvesToItsNewPlace() throws {
        let box = try Sandbox()
        let a = box.root.appendingPathComponent("Old", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        let store = makeStore(box)
        #expect(store.store(a))
        let moved = box.root.appendingPathComponent("New", isDirectory: true)
        try FileManager.default.moveItem(at: a, to: moved)
        guard case .url(let url) = store.resolve() else { Issue.record("did not follow the move"); return }
        #expect(url.lastPathComponent == "New")
    }
}
