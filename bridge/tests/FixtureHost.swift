import Foundation

// The native endpoint runs on a real main run loop, just as it does in Finger.
// This fixture is compiled only by the isolated wire test.
@main
private struct FixtureHost {
  static func main() throws {
    let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let files = try FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: nil
    )
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    var selection = FingerAgentSelection(folder: folder, files: files)
    let endpoint = FingerAgentEndpoint()
    try endpoint.start(
      selection: { selection },
      showCollection: { name, items in
        selection = FingerAgentSelection(folder: nil, collection: name, paths: { items })
      })
    // The test driver performs the filesystem mutation, then sends the exact
    // committed mapping that Browser.remap would publish on its UI thread.
    DispatchQueue.global().async {
      while let line = readLine() {
        guard let changes = try? JSONDecoder().decode([String: String].self, from: Data(line.utf8))
        else { continue }
        DispatchQueue.main.async {
          endpoint.remap(changes)
          print("remapped")
          fflush(stdout)
        }
      }
    }
    print("ready")
    fflush(stdout)
    withExtendedLifetime(endpoint) { RunLoop.main.run() }
  }
}
