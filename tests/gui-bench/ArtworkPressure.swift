import AppKit

func checkArtworkPressure(_ b: Browser, project: URL) throws {
  b.visit(project.path)
  try spin(
    until: {
      b.folderPath == project.path && !b.loading && b.entries.contains { $0.name == "Notes.txt" }
    }, "artwork fixture")
  var textTimes: [Double] = []
  var pending = 0
  func pictures() -> [NSImageView] {
    tree(b.ui.preview).compactMap {
      String(describing: type(of: $0)) == "PreviewPicture" ? $0 as? NSImageView : nil
    }
  }
  func frames() -> [NSRect] {
    tree(b.ui.preview).compactMap { view in
      guard view is PreviewTarget else { return nil }
      return b.ui.preview.convert(view.bounds, from: view)
    }
  }
  for trial in 0..<10 {
    let folder = "Exports " + String(trial)
    try select(b, named: folder)
    try spin(
      until: {
        pictures().count == 3
          && tree(b.ui.preview).contains { ($0 as? NSTextField)?.stringValue == folder }
      }, "three large artwork cards")
    b.ui.root.layoutSubtreeIfNeeded()
    if trial == 0 {
      let original = frames()
      let start = DispatchTime.now().uptimeNanoseconds
      try spin(until: { pictures().allSatisfy { $0.image != nil } }, "three 23-megapixel PNGs")
      b.ui.root.layoutSubtreeIfNeeded()
      try require(
        original.count == 6 && original == frames(),
        "A decoded thumbnail shifted a card or child row")
      print(
        String(
          format: "Three 6,400 × 3,600 PNGs arrived in %.2f ms with all six frames unchanged.",
          ms(start)))
      continue
    }
    pump(0.025)
    if pictures().contains(where: { $0.image == nil }) { pending += 1 }
    let start = DispatchTime.now().uptimeNanoseconds
    try select(b, named: "Notes.txt")
    try spin(
      until: {
        tree(b.ui.preview).contains {
          ($0 as? NSTextView)?.string == "Small local text after a busy image preview."
        }
      }, "new text preview during decoding")
    textTimes.append(ms(start))
  }
  summary("Text preview after selecting away from large PNGs", textTimes)
  print("Artwork was still arriving in \(pending) of \(textTimes.count) trials.")
}
