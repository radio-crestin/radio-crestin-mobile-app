//
//  FCPListSection.swift
//  flutter_carplay
//
//  Created by Oğuzhan Atalay on 21.08.2021.
//

import CarPlay

@available(iOS 14.0, *)
class FCPListSection {
  private(set) var _super: CPListSection?
  private(set) var elementId: String
  private var header: String?
  private var objcItems: [FCPListItem]
  private var sectionIndexEnabled: Bool

  init(obj: [String : Any], sectionIndexEnabled: Bool = true) {
    self.elementId = obj["_elementId"] as! String
    self.header = obj["header"] as? String
    self.sectionIndexEnabled = sectionIndexEnabled
    self.objcItems = (obj["items"] as! Array<[String : Any]>).map {
      FCPListItem(obj: $0)
    }
  }

  // The native rows are built here rather than in `init`, so the rows
  // `adoptItems` takes over are never built a second time.
  var get: CPListSection {
    let indexTitle = sectionIndexEnabled ? header : nil
    let listSection = CPListSection.init(
      items: objcItems.map { $0.get },
      header: header,
      sectionIndexTitle: indexTitle
    )
    self._super = listSection
    return listSection
  }

  public func getItems() -> [FCPListItem] {
    return objcItems
  }

  // Takes over the rows of the shown list that come again, by element id
  // (see `FCPListItem.adopt`). Each is taken once, since a native row
  // can't be on a list twice.
  public func adoptItems(from shown: inout [String: FCPListItem]) {
    for item in objcItems {
      if let existing = shown.removeValue(forKey: item.elementId) {
        item.adopt(existing)
      }
    }
  }
}
