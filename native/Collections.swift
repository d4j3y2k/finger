import AppKit

extension Browser {
  func renameCollection(_ record: CollectionRecord) {
    prompt("Rename collection", value: record.name, action: "Rename") { [weak self] name in
      guard let self, let index = collections.firstIndex(where: { $0.id == record.id }) else {
        return
      }
      let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty else {
        message("Enter a collection name.", error: true)
        return
      }
      collections[index].name = String(value.prefix(120))
      persistCollections()
      updateChrome()
    }
  }
  func removeCollection(_ record: CollectionRecord) {
    let alert = NSAlert()
    alert.messageText = "Remove “" + record.name + "” from Collections?"
    alert.informativeText = "The original files stay in their folders."
    alert.addButton(withTitle: "Remove Collection")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { [weak self] result in
      guard result == .alertFirstButtonReturn, let self else { return }
      collections.removeAll { $0.id == record.id }
      persistCollections()
      navigate(
        [
          "op": "forget", "key": "collection:" + record.id,
          "fallback": project ?? NSHomeDirectory(), "state": snapshot(),
        ], selecting: nil, animate: false)
      message("Removed collection")
    }
  }
  func collectionMenu(_ key: String) -> NSMenu? {
    guard let record = collections.first(where: { "collection:" + $0.id == key }) else {
      return nil
    }
    let menu = NSMenu()
    menu.addItem(CommandItem("Open Collection") { [weak self] in self?.visit(key) })
    menu.addItem(
      CommandItem("Rename Collection…") { [weak self] in self?.renameCollection(record) })
    menu.addItem(
      CommandItem("Remove Collection…") { [weak self] in self?.removeCollection(record) })
    return menu
  }
  func rebuildCollectionsMenu() {
    guard let menu = browseCollectionsMenu else { return }
    menu.removeAllItems()
    for record in collections {
      let item = CommandItem(record.name) { [weak self] in self?.visit("collection:" + record.id) }
      item.state = collection?.id == record.id ? .on : .off
      menu.addItem(item)
    }
    if collections.isEmpty {
      let empty = NSMenuItem(title: "No Collections", action: nil, keyEquivalent: "")
      empty.isEnabled = false
      menu.addItem(empty)
    }
  }
}
