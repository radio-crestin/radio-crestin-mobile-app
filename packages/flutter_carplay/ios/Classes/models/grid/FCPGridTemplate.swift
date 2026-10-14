//
//  FCPGridTemplate.swift
//  flutter_carplay
//
//  Created by Oğuzhan Atalay on 21.08.2021.
//

import CarPlay

@available(iOS 14.0, *)
class FCPGridTemplate {
  private(set) var _super: CPGridTemplate?
  private(set) var elementId: String
  private var title: String
  private var systemIcon: String?
  private var buttons: [CPGridButton]
  private var objcButtons: [FCPGridButton]
  
  init(obj: [String : Any]) {
    self.elementId = obj["_elementId"] as! String
    self.title = obj["title"] as! String
    self.systemIcon = obj["systemIcon"] as? String
    self.objcButtons = (obj["buttons"] as! Array<[String : Any]>).map {
      FCPGridButton(obj: $0)
    }
    self.buttons = self.objcButtons.map {
      $0.get
    }
  }
  
  var get: CPTemplate {
    let gridTemplate = CPGridTemplate.init(title: self.title, gridButtons: self.buttons)
    // Shown when the grid is a tab of a tab bar.
    if let systemIcon = self.systemIcon {
      gridTemplate.tabTitle = self.title
      gridTemplate.tabImage = UIImage(systemName: systemIcon)
    }
    gridTemplate.elementId = self.elementId
    self._super = gridTemplate
    return gridTemplate
  }
}

@available(iOS 14.0, *)
extension FCPGridTemplate: FCPRootTemplate { }
