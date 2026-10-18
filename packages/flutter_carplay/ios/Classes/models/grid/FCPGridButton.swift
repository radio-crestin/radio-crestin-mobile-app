//
//  FCPGridButton.swift
//  flutter_carplay
//
//  Created by Oğuzhan Atalay on 21.08.2021.
//

import CarPlay

@available(iOS 14.0, *)
class FCPGridButton {
  private(set) var _super: CPGridButton?
  private(set) var elementId: String
  private var titleVariants: [String]
  private(set) var image: String
  // The pinned-row picture once it loaded (see `loadHeaderImage`).
  private(set) var headerImage: UIImage?
  private var headerImageFailed = false
  // The list showing this button in its pinned row, told when the
  // picture arrives.
  weak var headerOwner: FCPListTemplate?

  init(obj: [String : Any]) {
    self.elementId = obj["_elementId"] as! String
    self.titleVariants = obj["titleVariants"] as! [String]
    self.image = obj["image"] as! String
  }

  var get: CPGridButton {
    let image: UIImage
    let imageSource = self.image.toImageSource()

    if #available(iOS 26.0, *) {
      image = makeSafeUIPlaceholder()
    } else {
      image = makeUIImage(from: imageSource)
    }

    let gridButton = makeButton(image: image)

    if #available(iOS 26.0, *) {
      loadUIImageAsync(from: imageSource) { uiImage in
        if let uiImage = uiImage {
          gridButton.perform(Selector("updateImage:"), with: uiImage)
        }
      }
    }
    return gridButton
  }

  // A button for the pinned row above a list (iOS 26+): the loaded
  // picture, a question mark while a failed download waits, or the
  // placeholder until then. On iOS 27 `updateImage` on a pinned button
  // left it blank in the car, so the list sends fresh buttons instead.
  var headerButton: CPGridButton {
    let failed = headerImageFailed ? UIImage(systemName: "questionmark") : nil
    return makeButton(image: headerImage ?? failed ?? makeSafeUIPlaceholder())
  }

  // Takes the picture one of `shown` already loaded for the same image, so
  // a reordered pinned row doesn't blink.
  func reuseHeaderImage(from shown: [FCPGridButton]) {
    if let loaded = shown.first(where: { $0.image == image })?.headerImage {
      headerImage = loaded
    }
  }

  // Loads the pinned-row picture and tells `headerOwner`. A download that
  // fails shows a question mark and runs again on `retryFailedImages`.
  func loadHeaderImage() {
    let source = image.toImageSource()
    loadRowImage(image) { [weak self] uiImage in
      guard let self = self else { return }
      self.headerImage = uiImage.map {
        FCPGridButton.pinnedRowImage($0, from: source)
      }
      self.headerImageFailed = uiImage == nil
      self.headerOwner?.headerImageDidLoad(for: self)
    }
  }

  // Station pictures get the rounded corners of list rows; symbols (the
  // "all favorites" dots, a question mark) and app assets stay as they are.
  private static func pinnedRowImage(_ uiImage: UIImage, from source: ImageSource) -> UIImage {
    switch source {
    case .url, .file:
      return uiImage.isSymbolImage ? uiImage : makeRoundedSquareImage(from: uiImage)
    case .flutterAsset, .systemSymbol, .symbolTile:
      return uiImage
    }
  }

  private func makeButton(image: UIImage) -> CPGridButton {
    let gridButton = CPGridButton(
      titleVariants: self.titleVariants,
      image: image,
      handler: { _ in
        DispatchQueue.main.async {
          FCPStreamHandlerPlugin.sendEvent(
            type: FCPChannelTypes.onGridButtonPressed,
            data: ["elementId": self.elementId]
          )
        }
      }
    )
    gridButton.isEnabled = true
    self._super = gridButton
    return gridButton
  }
}
