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
