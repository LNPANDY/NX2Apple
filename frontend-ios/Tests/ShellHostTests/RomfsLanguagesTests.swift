import Foundation
import Testing
@testable import ShellHost

/// `RomfsLanguages` reads the `DMROMFS1` index a game's `romfs.img` ends with (LNPANDY/NX2Apple#668).
@Suite struct RomfsLanguagesTests {
    /// A node of a RomFS tree: a directory (children) or a file (bytes).
    private indirect enum Node {
        case dir([String: Node])
        case file([UInt8])
    }

    /// Packs `root` the way `dm/tools/romfs_image.py` does: a 32-byte header, the file data, then 24-byte entries and one name pool.
    /// Entry 0 is the root, children are consecutive and sorted by name bytes, directories are numbered breadth-first,
    /// a directory has type 0 and a file type 1.
    private static func image(_ root: Node) -> Data {
        struct Item { var name: [UInt8]; var node: Node; var a: UInt64 = 0; var b: UInt64 = 0 }
        var items = [Item(name: [], node: root)]
        var i = 0
        while i < items.count {
            if case .dir(let kids) = items[i].node {
                let sorted = kids.map { (Array($0.key.utf8), $0.value) }.sorted { $0.0.lexicographicallyPrecedes($1.0) }
                items[i].a = UInt64(items.count)
                items[i].b = UInt64(sorted.count)
                items.append(contentsOf: sorted.map { Item(name: $0.0, node: $0.1) })
            }
            i += 1
        }
        var data = [UInt8](), offset: UInt64 = 32
        for k in items.indices {
            if case .file(let bytes) = items[k].node {
                items[k].a = offset
                items[k].b = UInt64(bytes.count)
                offset += UInt64(bytes.count)
                data += bytes
            }
        }
        func le(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> (8 * UInt64($0))) & 0xff) } }
        var idx = [UInt8](), pool = [UInt8]()
        for item in items {
            let isDir: Bool
            if case .dir = item.node { isDir = true } else { isDir = false }
            idx += le(item.a, 8) + le(item.b, 8) + le(UInt64(pool.count), 4) + le(UInt64(item.name.count), 2) + [isDir ? 0 : 1, 0]
            pool += item.name
        }
        let head = [UInt8]("DMROMFS1".utf8) + le(offset, 8) + le(UInt64(idx.count + pool.count), 8) + le(UInt64(items.count), 8)
        return Data(head + data + idx + pool)
    }

    private func folder(with img: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("romfs-lang-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try img.write(to: dir.appendingPathComponent("romfs.img"))
        return dir
    }

    private func codes(_ img: Data) throws -> [String] {
        RomfsLanguages.options(in: try folder(with: img)).map { $0[0] }
    }

    private func mask(_ text: String) -> Node {
        .dir(["System": .dir(["RegionLangMask.txt": .file(Array(text.utf8))]), "Other": .file([1, 2, 3])])
    }

    @Test func aRealLayoutImageGivesTheMaskLanguages() throws {
        #expect(try codes(Self.image(mask("JPja USen CNzh TWzh EUfr\n01111\n"))) == ["en-US", "ja", "fr", "zh-Hant", "zh-Hans"])
    }

    @Test func theMalsFolderIsUsedWhenThereIsNoMask() throws {
        let tree = Node.dir(["Mals": .dir(["USen.Product.100.sarc.zs": .file([0]), "JPja.Product.100.sarc.zs": .file([0]),
                                           "Readme.txt": .file([0])])])
        #expect(try codes(Self.image(tree)) == ["en-US", "ja"])
    }

    @Test func aSingleLanguageGivesNoRow() throws {
        #expect(try codes(Self.image(mask("USen\n"))) == [])
    }

    @Test func unknownTagsAreIgnored() throws {
        #expect(try codes(Self.image(mask("ZZxx QQqq USen\n"))) == [])
        #expect(try codes(Self.image(mask("ZZxx USen JPja\n"))) == ["en-US", "ja"])
    }

    @Test func aBadMagicGivesNoRow() throws {
        var img = Self.image(mask("USen JPja\n"))
        img[0] = UInt8(ascii: "X")
        #expect(try codes(img) == [])
    }

    @Test func aTruncatedFileGivesNoRow() throws {
        let img = Self.image(mask("USen JPja\n"))
        #expect(try codes(img.prefix(img.count - 10)) == [])
        #expect(try codes(img.prefix(20)) == [])
        #expect(try codes(Data()) == [])
    }

    @Test func aCraftedHeaderDoesNotTrap() throws {
        func patched(_ offset: Int, _ value: UInt64, in base: Data? = nil) -> Data {
            var d = base ?? Self.image(mask("USen JPja\n"))
            for i in 0..<8 { d[offset + i] = UInt8((value >> (8 * UInt64(i))) & 0xff) }
            return d
        }
        #expect(try codes(patched(24, .max)) == [], "a huge entry count must not overflow count * 24")
        #expect(try codes(patched(24, UInt64.max / 24 + 1)) == [])
        #expect(try codes(patched(8, .max)) == [])
        #expect(try codes(patched(16, .max)) == [])
        let img = Self.image(mask("USen JPja\n"))
        let idxOff = Int(img[8]) | Int(img[9]) << 8
        // Entries sorted by name: Other is entry 1 and System entry 2, whose child RegionLangMask.txt is entry 3.
        #expect(try codes(patched(idxOff + 3 * 24, .max, in: img)) == [], "a mask offset near UInt64.max must not overflow offset + size")
        #expect(try codes(patched(idxOff + 3 * 24 + 8, .max, in: img)) == [])
    }
}
