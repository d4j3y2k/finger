import AppKit

enum CodexHandoff {
  static func prompt(for entries: [Entry]) -> String {
    let paths = entries.map { $0.path.debugDescription }.joined(separator: "\n")
    return "Files selected in Finger:\n\n" + paths
  }

  static func draftURL(prompt: String) -> URL? {
    var components = URLComponents()
    components.scheme = "codex"
    components.host = "new"
    components.queryItems = [URLQueryItem(name: "prompt", value: prompt)]
    // URLSearchParams in the desktop client treats a literal '+' as a space.
    components.percentEncodedQuery = components.percentEncodedQuery?
      .replacingOccurrences(of: "+", with: "%2B")
    return components.url
  }
}

extension Browser {
  func handToCodex(_ completion: @escaping (String) -> Void) {
    guard let homeSelection, !homeSelection.isEmpty else {
      completion("Select a file first.")
      return
    }
    let prompt = CodexHandoff.prompt(for: homeSelection)
    let clipboard = self.clipboard
    func copyForPaste() {
      clipboard.clearContents()
      if clipboard.setString(prompt, forType: .string) {
        completion("Selection copied. Paste it into Codex.")
      } else {
        completion("Couldn't open Codex or copy the selection.")
      }
    }
    let bundleID = "com.openai.codex"
    let app =
      NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.bundleURL
      ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    guard let app, let url = CodexHandoff.draftURL(prompt: prompt) else {
      copyForPaste()
      return
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.addsToRecentItems = false
    configuration.promptsUserIfNeeded = false
    NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) {
      application, error in
      DispatchQueue.main.async {
        if application != nil, error == nil {
          completion("Opened selection in Codex.")
        } else {
          copyForPaste()
        }
      }
    }
  }
}
