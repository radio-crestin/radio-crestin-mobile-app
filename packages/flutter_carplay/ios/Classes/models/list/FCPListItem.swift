//
//  FCPListItem.swift
//  flutter_carplay
//
//  Created by Oğuzhan Atalay on 21.08.2021.
//

import CarPlay

@available(iOS 14.0, *)
class FCPListItem {
  private(set) var _super: CPListItem?
  private(set) var elementId: String
  private var text: String
  private var detailText: String?
  private var isOnPressListenerActive: Bool = false
  private var completeHandler: (() -> Void)?
  private var image: String?
  private var playbackProgress: CGFloat?
  private var isPlaying: Bool?
  private var playingIndicatorLocation: CPListItemPlayingIndicatorLocation?
  private var accessoryType: CPListItemAccessoryType?
  
  init(obj: [String : Any]) {
    self.elementId = obj["_elementId"] as! String
    self.text = obj["text"] as! String
    self.detailText = obj["detailText"] as? String
    self.isOnPressListenerActive = obj["onPress"] as? Bool ?? false
    self.image = obj["image"] as? String
    self.playbackProgress = obj["playbackProgress"] as? CGFloat
    self.isPlaying = obj["isPlaying"] as? Bool
    self.setPlayingIndicatorLocation(fromString: obj["playingIndicatorLocation"] as? String)
    self.setAccessoryType(fromString: obj["accessoryType"] as? String)
  }

  private func handler(selectedItem: CPSelectableListItem, complete: @escaping () -> Void) {
    if isOnPressListenerActive {
      completeHandler = complete

      DispatchQueue.main.async {
        FCPStreamHandlerPlugin.sendEvent(
          type: FCPChannelTypes.onListItemSelected,
          data: ["elementId": self.elementId]
        )
      }
    } else {
      complete()
    }
  }

  // The native row, built on first use. A row taken over from the list
  // shown before (`adopt`) comes back as it is, with its picture.
  var get: CPListItem {
    if let listItem = _super {
      return listItem
    }
    let listItem = CPListItem.init(text: text, detailText: detailText)
    listItem.handler = self.handler
    // An empty string is "no image", not an asset name to look up.
    if let image = image, !image.isEmpty {
      FCPListItem.loadImage(image, into: listItem)
    }
    if playbackProgress != nil {
      listItem.playbackProgress = playbackProgress!
    }
    if isPlaying != nil {
      listItem.isPlaying = isPlaying!
    }
    if playingIndicatorLocation != nil {
      listItem.playingIndicatorLocation = playingIndicatorLocation!
    }
    if accessoryType != nil {
      listItem.accessoryType = accessoryType!
    }
    self._super = listItem
    return listItem
  }
  
  // Shows `image` on `listItem`: a picture loaded ahead (`FCPImageCache`)
  // at once, any other the placeholder at once and the picture once it
  // loads. A download that fails shows a question mark and runs again on
  // `retryFailedImages`. The request is kept on the row (`userInfo`), not
  // on this object, which section updates swap for a fresh one while the
  // row stays: a load the row no longer asks for is dropped.
  private static func loadImage(_ image: String, into listItem: CPListItem) {
    listItem.userInfo = image
    if let loaded = FCPImageCache.image(for: image) {
      listItem.setImage(loaded)
      return
    }
    listItem.setImage(makeSafeUIPlaceholder())
    fetchImage(image, into: listItem)
  }

  private static func fetchImage(_ image: String, into listItem: CPListItem) {
    let source = image.toImageSource()
    guard case .url(let url) = source else {
      loadUIImageAsync(from: source) { [weak listItem] uiImage in
        guard let listItem = listItem, let uiImage = uiImage,
              listItem.userInfo as? String == image else { return }
        listItem.setImage(uiImage)
      }
      return
    }
    downloadUIImage(from: url) { [weak listItem] uiImage in
      guard let listItem = listItem,
            listItem.userInfo as? String == image else { return }
      if let uiImage = uiImage {
        listItem.setImage(uiImage)
        return
      }
      listItem.setImage(UIImage(systemName: "questionmark"))
      FCPImageRetry.add { [weak listItem] in
        guard let listItem = listItem,
              listItem.userInfo as? String == image else { return }
        fetchImage(image, into: listItem)
      }
    }
  }

  public func stopHandler() {
    guard self.completeHandler != nil else {
      return
    }
    self.completeHandler!()
    self.completeHandler = nil
  }
  
  public func update(text: String?, detailText: String?, image: String?, playbackProgress: CGFloat?, isPlaying: Bool?, playingIndicatorLocation: String?, accessoryType: String?) {
    if text != nil {
      self._super?.setText(text!)
      self.text = text!
    }
    if detailText != nil {
      self._super?.setDetailText(detailText)
      self.detailText = detailText
    }

    if let image = image, !image.isEmpty, image != self.image {
      if let listItem = self._super {
        FCPListItem.loadImage(image, into: listItem)
      }
      self.image = image
    } else if image == nil || image?.isEmpty == true {
      self.image = nil
      self._super?.userInfo = nil
      self._super?.setImage(nil)
    }

    if playbackProgress != nil {
      self._super?.playbackProgress = playbackProgress!
      self.playbackProgress = playbackProgress
    }
    if isPlaying != nil {
      self._super?.isPlaying = isPlaying!
      self.isPlaying = isPlaying
    }
    if playingIndicatorLocation != nil {
      self.setPlayingIndicatorLocation(fromString: playingIndicatorLocation)
      if self.playingIndicatorLocation != nil {
        self._super?.playingIndicatorLocation = self.playingIndicatorLocation!
      }
    }
    if accessoryType != nil {
      self.setAccessoryType(fromString: accessoryType)
      if self.accessoryType != nil {
        self._super?.accessoryType = self.accessoryType!
      }
    }
  }
  
  private func setPlayingIndicatorLocation(fromString: String?) {
    if fromString == "leading" {
      self.playingIndicatorLocation = CPListItemPlayingIndicatorLocation.leading
    } else if fromString == "trailing" {
      self.playingIndicatorLocation = CPListItemPlayingIndicatorLocation.trailing
    }
  }
  
  private func setAccessoryType(fromString: String?) {
    if fromString == "cloud" {
      self.accessoryType = CPListItemAccessoryType.cloud
    } else if fromString == "disclosureIndicator" {
      self.accessoryType = CPListItemAccessoryType.disclosureIndicator
    } else {
      self.accessoryType = CPListItemAccessoryType.none
    }
  }

  // Takes over the native row of `shown`, the same row on the list shown
  // before, and brings it up to date. A list sent again around the same
  // rows then keeps each row and its loaded picture: a row built again
  // loads its picture again, and CarPlay decodes and scales every picture
  // on the main thread (~2 ms a row, ~140 ms for the Home list).
  func adopt(_ shown: FCPListItem) {
    guard let listItem = shown._super else { return }
    _super = listItem
    completeHandler = shown.completeHandler
    listItem.handler = self.handler
    if listItem.text != text {
      listItem.setText(text)
    }
    if listItem.detailText != detailText {
      listItem.setDetailText(detailText)
    }
    if image != shown.image {
      if let image = image, !image.isEmpty {
        FCPListItem.loadImage(image, into: listItem)
      } else {
        listItem.userInfo = nil
        listItem.setImage(nil)
      }
    }
    if let playbackProgress = playbackProgress {
      listItem.playbackProgress = playbackProgress
    }
    if let isPlaying = isPlaying {
      listItem.isPlaying = isPlaying
    }
    if let playingIndicatorLocation = playingIndicatorLocation {
      listItem.playingIndicatorLocation = playingIndicatorLocation
    }
    if let accessoryType = accessoryType {
      listItem.accessoryType = accessoryType
    }
  }
}
