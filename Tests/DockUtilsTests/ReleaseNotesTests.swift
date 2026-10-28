import Foundation
import Testing

struct ReleaseNotesTests {
  private static let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  private func notes(_ tag: String, changelog: String) throws -> String {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("CHANGELOG-\(UUID()).md")
    try changelog.write(to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: file) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [Self.root.appendingPathComponent("scripts/release-notes.sh").path, tag]
    process.environment = ["CHANGELOG": file.path, "PATH": "/usr/bin:/bin"]
    let out = Pipe()
    process.standardOutput = out
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    return String(decoding: data, as: UTF8.self)
  }

  private let changelog = """
    # Changelog

    ## 2.1.0

    - final

    ## 2.1.0-beta1

    - beta

    ## 2.0.0

    - old
    """

  @Test func finalReleaseIncludesItsPrereleases() throws {
    let text = try notes("2.1.0", changelog: changelog)
    #expect(text.hasPrefix("# 2.1.0\n"))
    #expect(text.contains("- final"))
    #expect(text.contains("- beta"))
    #expect(!text.contains("- old"))
  }

  @Test func prereleaseHasOnlyItsOwnSection() throws {
    let text = try notes("2.1.0-beta1", changelog: changelog)
    #expect(text.contains("- beta"))
    #expect(!text.contains("- final"))
    #expect(!text.contains("- old"))
  }
}
