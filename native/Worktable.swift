import AppKit

extension Browser {
  var contextualProject: String? {
    guard let folder = folderPath else { return project }
    guard let project else { return folder }
    let key = FolderReferences.key(folder)
    let root = FolderReferences.key(project)
    return key == root || key.hasPrefix(root == "/" ? root : root + "/") ? project : folder
  }

  func configureWorktable() {
    ui.onWorktable = { [weak self] in self?.showWorktable() }
    homeView.onSelection = { [weak self] entries in
      guard let self, isWorktable else { return }
      homeSelection = entries
    }
    homeView.onBrowse = { [weak self] in self?.browseFromWorktable() }
    homeView.onChooseProject = { [weak self] in self?.chooseFolder() }
    homeView.onPractice = { [weak self] in self?.openDemo() }
    homeView.onPreview = { [weak self] in self?.quickLook() }
    homeView.onHandoff = { [weak self] in
      guard let self else { return }
      if let files = homeSelection { homeHistory.recordUse(files) }
      handToCodex { [weak self] status in self?.homeView.notice(status) }
    }
  }

  func showWorktable(project chosen: String? = nil) {
    guard !busy, window.attachedSheet == nil else { return }
    if isWorktable, chosen == nil {
      window.makeFirstResponder(homeView)
      return
    }
    let root = chosen ?? contextualProject ?? NSHomeDirectory()
    if !isWorktable { saveWorkspace() }
    browseDestination = chosen == nil && !location.isEmpty ? (location, nil) : (root, nil)
    if previewPanel?.isVisible == true { dismissQuickLook() }
    window.cancelHistorySwipe()
    project = root
    UserDefaults.standard.set(root, forKey: "worktableProject")
    homeHistory = ResumeHistory()
    homeVisitDate = Date()
    homeSelection = []
    window.contentView = homeView
    window.title = "Worktable — " + URL(fileURLWithPath: root).lastPathComponent
    window.representedURL = URL(fileURLWithPath: root, isDirectory: true)
    window.makeFirstResponder(homeView)
    installMenu()
    homeView.begin(project: root)
    refreshWorktable()
  }

  func refreshWorktable() {
    guard isWorktable, let project else { return }
    homeTicket?.cancel()
    let ticket = FileReadTicket()
    homeTicket = ticket
    let history = homeHistory
    let visits = recent
    let date = homeVisitDate
    listingQueue.async { [weak self] in
      let result = Result {
        try ResumeCatalog.scan(
          project: project, recentFolders: visits, history: history,
          cancelled: { ticket.cancelled })
      }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.homeTicket === ticket, self.isWorktable else { return }
        self.homeTicket = nil
        switch result {
        case .success(let catalog):
          history.markVisit(project: project, at: date)
          self.homeView.show(catalog)
        case .failure(let error):
          self.homeView.showError(error.localizedDescription)
        }
      }
    }
  }

  func leaveWorktable() {
    homeTicket?.cancel()
    homeTicket = nil
    if previewPanel?.isVisible == true { dismissQuickLook() }
    homeSelection = nil
    browseDestination = nil
    window.contentView = ui.root
    window.makeFirstResponder(ui.table)
    installMenu()
    updateChrome()
  }

  func browseFromWorktable() {
    guard isWorktable else { return }
    let destination = browseDestination ?? (project ?? NSHomeDirectory(), nil)
    if destination.key == location && destination.state == nil {
      leaveWorktable()
    } else {
      navigate(
        ["op": "visit", "key": destination.key, "state": snapshot()],
        selecting: nil, animate: false, restoring: destination.state)
    }
  }
}
