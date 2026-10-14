//
//  FCPListTemplate.swift
//  flutter_carplay
//
//  Created by Oğuzhan Atalay on 21.08.2021.
//

import CarPlay

@available(iOS 14.0, *)
class FCPListTemplate {
  private(set) var _super: CPListTemplate?
  private(set) var elementId: String
  private var title: String?
  private var systemIcon: String
  private var sections: [CPListSection] = []
  private var objcSections: [FCPListSection] = []
  private var emptyViewTitleVariants: [String] = []
  private var emptyViewSubtitleVariants: [String] = []
  private var showsTabBadge: Bool = false
  private var templateType: FCPListTemplateTypes
  private var objcBackButton: FCPBarButton?
  private var backButton: CPBarButton?
  private var sectionIndexEnabled: Bool = true
  private var objcHeaderGridButtons: [FCPGridButton] = []
  private var objcHeaderImageRow: FCPImageRow?
  // The row of pictures as the first section, ahead of `sections`.
  private var headerImageRowSection: CPListSection?
  private var headerRedraw: DispatchWorkItem?

  init(obj: [String : Any], templateType: FCPListTemplateTypes) {
    self.elementId = obj["_elementId"] as! String
    self.title = obj["title"] as? String
    self.systemIcon = obj["systemIcon"] as! String
    self.emptyViewTitleVariants = obj["emptyViewTitleVariants"] as? [String] ?? []
    self.emptyViewSubtitleVariants = obj["emptyViewSubtitleVariants"] as? [String] ?? []
    self.showsTabBadge = obj["showsTabBadge"] as! Bool
    self.sectionIndexEnabled = obj["sectionIndexEnabled"] as? Bool ?? true
    self.templateType = templateType
    self.objcSections = (obj["sections"] as! Array<[String : Any]>).map {
      FCPListSection(obj: $0, sectionIndexEnabled: self.sectionIndexEnabled)
    }
    self.sections = self.objcSections.map {
      $0.get
    }
    self.objcHeaderGridButtons = (obj["headerGridButtons"] as? Array<[String : Any]> ?? []).map {
      FCPGridButton(obj: $0)
    }
    self.objcHeaderImageRow = (obj["headerImageRow"] as? [String : Any]).map {
      FCPImageRow(obj: $0)
    }
    let backButtonData = obj["backButton"] as? [String : Any]
    if backButtonData != nil {
      self.objcBackButton = FCPBarButton(obj: backButtonData!)
      self.backButton = self.objcBackButton?.get
    }
  }
  
  var get: CPTemplate {
    buildHeaderImageRowSection()
    let listTemplate = CPListTemplate.init(title: title, sections: allSections)
    listTemplate.emptyViewTitleVariants = emptyViewTitleVariants
    listTemplate.emptyViewSubtitleVariants = emptyViewSubtitleVariants
    listTemplate.showsTabBadge = showsTabBadge
    listTemplate.tabImage = UIImage(systemName: systemIcon)
    if (templateType == FCPListTemplateTypes.DEFAULT) {
      listTemplate.backButton = self.backButton
    }
    listTemplate.elementId = self.elementId
    self._super = listTemplate
    applyHeaderGridButtons()
    loadHeaderImageRow()
    return listTemplate
  }

  // What CarPlay lists: the row of pictures, if any, then the sections.
  private var allSections: [CPListSection] {
    (headerImageRowSection.map { [$0] } ?? []) + sections
  }

  // Shows the row of pictures above the sections (iOS 26+), with the
  // pictures loaded so far.
  private func buildHeaderImageRowSection() {
    guard #available(iOS 26.0, *), let row = objcHeaderImageRow else {
      headerImageRowSection = nil
      return
    }
    headerImageRowSection = CPListSection(items: [row.get])
  }

  private func loadHeaderImageRow() {
    guard #available(iOS 26.0, *), let row = objcHeaderImageRow else { return }
    row.owner = self
    row.loadImages()
  }

  // Replaces the row of pictures; nil removes it. Pictures the shown row
  // already loaded for the same images are kept.
  public func updateHeaderImageRow(row: FCPImageRow?) {
    if let row = row, let shown = objcHeaderImageRow {
      row.reuseImages(from: shown)
    }
    objcHeaderImageRow = row
    redrawHeaderImageRow()
    loadHeaderImageRow()
  }

  // Sends the sections again with a fresh row: the documented way to
  // change what a shown list holds.
  private func redrawHeaderImageRow() {
    buildHeaderImageRowSection()
    _super?.updateSections(allSections)
  }

  func headerImageRowDidLoadImage(_ row: FCPImageRow) {
    guard row === objcHeaderImageRow else { return }
    scheduleHeaderRedraw()
  }

  // Pins the header grid buttons above the sections (iOS 26+); nil when
  // there are none, which hides the row. Pictures still loading follow in
  // `headerImageDidLoad`.
  private func applyHeaderGridButtons() {
    guard #available(iOS 26.0, *) else { return }
    adoptHeaderGridButtons()
    showHeaderGridButtons()
    for button in objcHeaderGridButtons where button.headerImage == nil {
      button.loadHeaderImage()
    }
  }

  private func adoptHeaderGridButtons() {
    objcHeaderGridButtons.forEach { $0.headerOwner = self }
  }

  @available(iOS 26.0, *)
  private func showHeaderGridButtons() {
    _super?.headerGridButtons = objcHeaderGridButtons.isEmpty
      ? nil
      : objcHeaderGridButtons.map { $0.headerButton }
  }

  // Sends the row again with the new picture. Pictures that arrive close
  // together (the cached ones) share one redraw rather than one each.
  func headerImageDidLoad(for button: FCPGridButton) {
    guard objcHeaderGridButtons.contains(where: { $0 === button }) else {
      return
    }
    scheduleHeaderRedraw()
  }

  private func scheduleHeaderRedraw() {
    headerRedraw?.cancel()
    let redraw = DispatchWorkItem { [weak self] in
      guard let self = self else { return }
      self.headerRedraw = nil
      if #available(iOS 26.0, *) {
        self.showHeaderGridButtons()
      }
      if self.objcHeaderImageRow != nil {
        self.redrawHeaderImageRow()
      }
    }
    headerRedraw = redraw
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: redraw)
  }

  public func updateHeaderGridButtons(buttons: [FCPGridButton]) {
    buttons.forEach { $0.reuseHeaderImage(from: objcHeaderGridButtons) }
    self.objcHeaderGridButtons = buttons
    applyHeaderGridButtons()
  }
  
  public func getSections() -> [FCPListSection] {
    return objcSections
  }

  public func merge(with: FCPListTemplate) -> FCPListTemplate {
    let copy = with
    self.updateSections(sections: copy.objcSections)
    // Same row: keep the shown one, so its pictures don't reload.
    if copy.objcHeaderImageRow?.elementId != self.objcHeaderImageRow?.elementId {
      self.updateHeaderImageRow(row: copy.objcHeaderImageRow)
    }
    // Same buttons: keep the shown ones, so their images don't reload.
    if copy.objcHeaderGridButtons.map({ $0.elementId })
        != self.objcHeaderGridButtons.map({ $0.elementId }) {
      self.updateHeaderGridButtons(buttons: copy.objcHeaderGridButtons)
    }
    copy._super = self._super
    copy.objcSections = self.objcSections
    copy.sections = self.sections
    copy.objcHeaderGridButtons = self.objcHeaderGridButtons
    copy.objcHeaderImageRow = self.objcHeaderImageRow
    copy.headerImageRowSection = self.headerImageRowSection
    // Pictures still loading report to the list that stays.
    copy.adoptHeaderGridButtons()
    copy.objcHeaderImageRow?.owner = copy
    if let redraw = self.headerRedraw {
      redraw.cancel()
      self.headerRedraw = nil
      copy.scheduleHeaderRedraw()
    }
    return copy;
  }

  // Shows `sections`. Rows already on this list keep their native row,
  // whichever section held them: Dart wraps the same rows in new sections
  // on each update.
  public func updateSections(sections: [FCPListSection]) {
    var shownItems = Dictionary(
      objcSections.flatMap { $0.getItems() }.map { ($0.elementId, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    sections.forEach { $0.adoptItems(from: &shownItems) }
    self.objcSections = sections
    self.sections = sections.map { $0.get }

    _super?.updateSections(allSections)
  }
}

@available(iOS 14.0, *)
extension FCPListTemplate: FCPRootTemplate { }
