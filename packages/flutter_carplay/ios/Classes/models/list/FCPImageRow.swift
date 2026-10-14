//
//  FCPImageRow.swift
//  flutter_carplay
//

import CarPlay

// A titled row of pictures above a list's sections (iOS 26+). CarPlay draws
// the pictures as rounded squares with a title under each, wrapping onto
// more lines when `allowsMultipleLines` is set.
@available(iOS 14.0, *)
class FCPImageRow {
  private(set) var elementId: String
  private var title: String
  private var elements: [FCPImageRowElement]
  private var allowsMultipleLines: Bool
  private var isTitlePressable: Bool
  // The list showing this row, told when a picture arrives.
  weak var owner: FCPListTemplate?

  init(obj: [String : Any]) {
    self.elementId = obj["_elementId"] as! String
    self.title = obj["title"] as! String
    self.elements = (obj["elements"] as? Array<[String : Any]> ?? []).map {
      FCPImageRowElement(obj: $0)
    }
    self.allowsMultipleLines = obj["allowsMultipleLines"] as? Bool ?? true
    self.isTitlePressable = obj["onTitlePress"] as? Bool ?? false
  }

  // Takes the pictures `shown` already loaded for the same images, so a
  // changed row doesn't blink.
  func reuseImages(from shown: FCPImageRow) {
    elements.forEach { $0.reuseImage(from: shown.elements) }
  }

  // Loads the pictures not loaded yet; `owner` hears of each one.
  func loadImages() {
    for element in elements where !element.isLoaded {
      element.loadImage { [weak self] in
        guard let self = self else { return }
        self.owner?.headerImageRowDidLoadImage(self)
      }
    }
  }

  // The row as CarPlay shows it, with the pictures loaded so far.
  @available(iOS 26.0, *)
  var get: CPListImageRowItem {
    let item = CPListImageRowItem(
      text: title,
      imageGridElements: elements.map { $0.get },
      allowsMultipleLines: allowsMultipleLines
    )
    item.listImageRowHandler = { [weak self] _, index, complete in
      defer { complete() }
      guard let self = self, self.elements.indices.contains(index) else {
        return
      }
      FCPImageRow.send(
        FCPChannelTypes.onImageRowElementPressed,
        elementId: self.elements[index].elementId
      )
    }
    if isTitlePressable {
      item.handler = { [weak self] _, complete in
        defer { complete() }
        guard let self = self else { return }
        FCPImageRow.send(FCPChannelTypes.onImageRowTitlePressed, elementId: self.elementId)
      }
    }
    return item
  }

  private static func send(_ type: String, elementId: String) {
    DispatchQueue.main.async {
      FCPStreamHandlerPlugin.sendEvent(type: type, data: ["elementId": elementId])
    }
  }
}

// One picture of an `FCPImageRow`, with its title.
@available(iOS 14.0, *)
class FCPImageRowElement {
  private(set) var elementId: String
  private var title: String
  private var image: String
  // The picture once loaded; nil until then and after a failed download.
  private var loadedImage: UIImage?
  private var failed = false

  init(obj: [String : Any]) {
    self.elementId = obj["_elementId"] as! String
    self.title = obj["title"] as! String
    self.image = obj["image"] as! String
  }

  var isLoaded: Bool { loadedImage != nil }

  // Takes the picture one of `shown` already loaded for the same image.
  func reuseImage(from shown: [FCPImageRowElement]) {
    if let loaded = shown.first(where: { $0.image == image })?.loadedImage {
      loadedImage = loaded
    }
  }

  // Loads the picture, then calls `onLoad` (main thread). A download that
  // fails shows a question mark and runs again on `retryFailedImages`.
  func loadImage(onLoad: @escaping () -> Void) {
    loadRowImage(image) { [weak self] uiImage in
      guard let self = self else { return }
      self.loadedImage = uiImage
      self.failed = uiImage == nil
      onLoad()
    }
  }

  // The loaded picture, a question mark while a failed download waits, or
  // the placeholder until the picture arrives.
  @available(iOS 26.0, *)
  var get: CPListImageRowItemImageGridElement {
    let failedImage = failed ? UIImage(systemName: "questionmark") : nil
    return CPListImageRowItemImageGridElement(
      image: loadedImage ?? failedImage ?? makeSafeUIPlaceholder(),
      imageShape: .roundedRectangle,
      title: title,
      accessorySymbolName: nil
    )
  }
}
