// With only the Command Line Tools (no Xcode), SwiftPM can't find swift-testing on its own. Run:
//   DEV=/Library/Developer/CommandLineTools/Library/Developer
//   swift test -Xswiftc -F$DEV/Frameworks -Xlinker -rpath -Xlinker $DEV/Frameworks -Xlinker -rpath -Xlinker $DEV/usr/lib
import Foundation
import Testing
@testable import FileExplorer

@MainActor @Test func newFoldersAreNumberedListedFirstAndRenameIsValidated() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data().write(to: dir.appending(path: "a.txt"))

    let model = Explorer(at: dir)
    model.newFolder()
    model.newFolder()
    #expect(model.visible.map(\.name) == ["New folder", "New folder (2)", "a.txt"])
    model.search = "folder (2)"
    #expect(model.visible.map(\.name) == ["New folder (2)"])
    model.search = ""
    #expect(uniqueURL("a.txt", in: dir).lastPathComponent == "a (2).txt")

    model.rename(dir.appending(path: "a.txt").path, to: "../escape.txt")
    #expect(model.errorMessage != nil)
    model.rename(dir.appending(path: "a.txt").path, to: "b.txt")
    #expect(model.visible.map(\.name).last == "b.txt")

    model.zip([dir.appending(path: "b.txt").path])
    #expect(model.visible.map(\.name).last == "b.txt.zip")
}

@MainActor @Test func droppedFilesAreCopiedAndFoldersCannotBeDroppedIntoThemselves() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let destination = root.appending(path: "Destination")
    let source = root.appending(path: "source.txt")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("dragged".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: root) }

    let model = Explorer(at: destination)
    let provider = try #require(NSItemProvider(contentsOf: source))
    #expect(await provider.loadFileURL() == source)
    #expect(model.drop([source], into: destination))
    #expect(model.visible.map(\.name) == ["source.txt"])
    #expect(try String(contentsOf: destination.appending(path: "source.txt"), encoding: .utf8) == "dragged")

    #expect(model.drop([source], into: destination))
    #expect(model.visible.map(\.name) == ["source (2).txt", "source.txt"])
    #expect(!model.drop([destination], into: destination))
}
