//
//  FlutterCarPlayPluginsSceneDelegate.swift
//  flutter_carplay
//
//  Created by Oğuzhan Atalay on 21.08.2021.
//

import CarPlay

extension CPTemplate {
  private static var elementIdKey: UInt8 = 0

  var elementId: String? {
    get {
      return objc_getAssociatedObject(self, &CPTemplate.elementIdKey) as? String
    }
    set {
      objc_setAssociatedObject(self, &CPTemplate.elementIdKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
  }
}

@available(iOS 14.0, *)
@objc(FlutterCarPlaySceneDelegate)
class FlutterCarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPInterfaceControllerDelegate {
  static private var interfaceController: CPInterfaceController?

  /// The tab each pushed template went onto, by element id. A tab bar keeps
  /// one navigation stack per tab: switching tabs hides the lists pushed on
  /// the tab left behind without popping them, and they are back when the
  /// driver returns, so they must stay known (their rows stay tappable).
  static private var pushedTemplateTabs: [String: ObjectIdentifier] = [:]

  static private var selectedTab: CPTemplate? {
    (interfaceController?.rootTemplate as? CPTabBarTemplate)?.selectedTemplate
  }

  /// Tracks whether the initial `sceneDidBecomeActive` after `didConnect` has
  /// been consumed. iOS fires `sceneDidBecomeActive` immediately after
  /// `didConnect`, producing a duplicate CONNECTED event. We suppress that
  /// first activation and only emit CONNECTED on subsequent foreground returns.
  private var _initialActivationConsumed = false

  static public func forceUpdateRootTemplate() {
    let rootTemplate = SwiftFlutterCarplayPlugin.rootTemplate
    let animated = SwiftFlutterCarplayPlugin.animated

    guard let rootTemplate = rootTemplate else { return }
    self.interfaceController?.setRootTemplate(rootTemplate, animated: animated)
  }

  // https://developer.apple.com/documentation/carplay/cplisttemplate/updatesections(_:)
  static public func updateListTemplateSections(elementId: String, sections: [FCPListSection]) {
    guard let templateFromHistory = SwiftFlutterCarplayPlugin.getTemplateFromHistory(elementId: elementId) as? FCPListTemplate  else {
      NSLog("FlutterCarPlaySceneDelegate - updateListTemplateSections: Template from history with elementId \(elementId) not found.")
      return
    }

    templateFromHistory.updateSections(sections: sections)
  }

  // https://developer.apple.com/documentation/carplay/cplisttemplate/headergridbuttons
  static public func updateListTemplateHeaderGridButtons(elementId: String, buttons: [FCPGridButton]) {
    guard let templateFromHistory = SwiftFlutterCarplayPlugin.getTemplateFromHistory(elementId: elementId) as? FCPListTemplate else {
      NSLog("FlutterCarPlaySceneDelegate - updateListTemplateHeaderGridButtons: Template from history with elementId \(elementId) not found.")
      return
    }

    templateFromHistory.updateHeaderGridButtons(buttons: buttons)
  }

  static public func updateListTemplateHeaderImageRow(elementId: String, row: FCPImageRow?) {
    guard let templateFromHistory = SwiftFlutterCarplayPlugin.getTemplateFromHistory(elementId: elementId) as? FCPListTemplate else {
      NSLog("FlutterCarPlaySceneDelegate - updateListTemplateHeaderImageRow: Template from history with elementId \(elementId) not found.")
      return
    }

    templateFromHistory.updateHeaderImageRow(row: row)
  }

  // https://developer.apple.com/documentation/carplay/cptabbartemplate/updatetemplates(_:)
  static public func updateTabBarTemplates(elementId: String, templates: Array<[String: Any]>) {
    guard let templateFromHistory = SwiftFlutterCarplayPlugin.getTemplateFromHistory(elementId: elementId) as? FCPTabBarTemplate  else {
        NSLog("FlutterCarPlaySceneDelegate - updateTabBarTemplates: TabBar template from history with elementId \(elementId) not found.")
        return
    }

    templateFromHistory.updateTemplates(newTemplatesData: templates)

    // A replaced tab takes the lists pushed on it along.
    let liveTabs = Set(templateFromHistory.tabTemplates.map { ObjectIdentifier($0) })
    forgetPushedTemplates { owner in !liveTabs.contains(owner) }
  }

  /// Drops the pushed templates whose tab matches `isGone`, telling Dart.
  static private func forgetPushedTemplates(where isGone: (ObjectIdentifier) -> Bool) {
    SwiftFlutterCarplayPlugin.templateStack.removeAll { stackTemplate in
      guard let owner = pushedTemplateTabs[stackTemplate.elementId], isGone(owner) else {
        return false
      }
      pushedTemplateTabs[stackTemplate.elementId] = nil
      SwiftFlutterCarplayPlugin.sendOnScreenBackButtonPressed(elementId: stackTemplate.elementId)
      return true
    }
  }

  // Fired when just before the carplay become active.
  // After `didConnect`, iOS fires this immediately — skip that first one to
  // avoid a duplicate CONNECTED event. Subsequent activations (returning from
  // background) are real and should emit CONNECTED.
  func sceneDidBecomeActive(_ scene: UIScene) {
    guard _initialActivationConsumed else {
      _initialActivationConsumed = true
      return
    }
    SwiftFlutterCarplayPlugin.onCarplayConnectionChange(status: FCPConnectionTypes.connected)
  }
  
  // Fired when carplay entered background
  func sceneDidEnterBackground(_ scene: UIScene) {
    SwiftFlutterCarplayPlugin.onCarplayConnectionChange(status: FCPConnectionTypes.background)
  }
  
  static public func pop(animated: Bool) {
    self.interfaceController?.popTemplate(animated: animated)
  }
  
  static public func popToRootTemplate(animated: Bool) {
    self.interfaceController?.popToRootTemplate(animated: animated)
  }
  
  static public func push(template: CPTemplate, animated: Bool) -> Bool {
    guard let interfaceController = self.interfaceController else { return false }
    guard interfaceController.rootTemplate != nil else { return false }

    if let elementId = template.elementId, let tab = selectedTab {
      pushedTemplateTabs[elementId] = ObjectIdentifier(tab)
    }
    interfaceController.pushTemplate(template, animated: animated)
    return true
  }

  static public func pushIfNotExist(template: CPTemplate, animated: Bool) -> Bool {
    guard let interfaceController = self.interfaceController else { return false }
    guard interfaceController.rootTemplate != nil else { return false }

    let isAlreadyPushed = interfaceController.templates.contains { $0 === template }
    let isTopSameInstance = interfaceController.topTemplate === template

    if !isAlreadyPushed && !isTopSameInstance {
        interfaceController.pushTemplate(template, animated: animated)
        return true
    }
    return false
  }

  func templateDidDisappear(_ template: CPTemplate, animated: Bool) {
      guard let interfaceController = FlutterCarPlaySceneDelegate.interfaceController else { return }

      let currentTemplates = interfaceController.templates
      let selectedTab = FlutterCarPlaySceneDelegate.selectedTab

      SwiftFlutterCarplayPlugin.templateStack.removeAll { stackTemplate in
          if currentTemplates.contains(where: { $0.elementId == stackTemplate.elementId }) {
              return false
          }
          // Pushed on another tab: hidden by a tab switch, not popped.
          if let owner = FlutterCarPlaySceneDelegate.pushedTemplateTabs[stackTemplate.elementId],
             let selectedTab = selectedTab,
             owner != ObjectIdentifier(selectedTab) {
              return false
          }
          FlutterCarPlaySceneDelegate.pushedTemplateTabs[stackTemplate.elementId] = nil
          SwiftFlutterCarplayPlugin.sendOnScreenBackButtonPressed(elementId: stackTemplate.elementId)
          return true
      }
  }

  static public func closePresent(animated: Bool) {
    self.interfaceController?.dismissTemplate(animated: animated)
  }

  static public func presentTemplate(template: CPTemplate, animated: Bool,
                                     onPresent: @escaping (_ completed: Bool) -> Void) {
    self.interfaceController?.presentTemplate(template, animated: animated, completion: { completed, error in
      guard error == nil else {
        onPresent(false)
        return
      }
      onPresent(completed)
    })
  }
  
  func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                didConnect interfaceController: CPInterfaceController) {
    FlutterCarPlaySceneDelegate.interfaceController = interfaceController
    interfaceController.delegate = self
    
    SwiftFlutterCarplayPlugin.onCarplayConnectionChange(status: FCPConnectionTypes.connected)
    let rootTemplate = SwiftFlutterCarplayPlugin.rootTemplate

    if let rootTemplate = rootTemplate {
      FlutterCarPlaySceneDelegate.interfaceController?.setRootTemplate(rootTemplate, animated: SwiftFlutterCarplayPlugin.animated, completion: nil)
    }
  }
  
  func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                didDisconnect interfaceController: CPInterfaceController, from window: CPWindow) {
    _initialActivationConsumed = false
    SwiftFlutterCarplayPlugin.onCarplayConnectionChange(status: FCPConnectionTypes.disconnected)
    // The car drops every pushed list; the next connection starts at the tabs.
    FlutterCarPlaySceneDelegate.forgetPushedTemplates { _ in true }

    interfaceController.delegate = nil
    FlutterCarPlaySceneDelegate.interfaceController = nil
  }

  func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                didDisconnectInterfaceController interfaceController: CPInterfaceController) {
    _initialActivationConsumed = false
    SwiftFlutterCarplayPlugin.onCarplayConnectionChange(status: FCPConnectionTypes.disconnected)
    FlutterCarPlaySceneDelegate.forgetPushedTemplates { _ in true }

    interfaceController.delegate = nil
    FlutterCarPlaySceneDelegate.interfaceController = nil
  }
}
