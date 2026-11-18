import Cocoa

class About {
  private var credits: NSMutableAttributedString {
    let text = "Kitzi is developed by ErciyeSoft, based on Maccy (MIT, © Alex Rodionov) "
      + "and DockDoor (GPL-3.0, © Ethan Bills)."
    let credits = NSMutableAttributedString(
      string: text,
      attributes: [NSAttributedString.Key.foregroundColor: NSColor.labelColor]
    )
    if let range = text.range(of: "Maccy") {
      credits.addAttribute(.link, value: "https://github.com/p0deje/Maccy", range: NSRange(range, in: text))
    }
    if let range = text.range(of: "DockDoor") {
      credits.addAttribute(.link, value: "https://github.com/ejbills/DockDoor", range: NSRange(range, in: text))
    }
    credits.setAlignment(.center, range: NSRange(location: 0, length: credits.length))
    return credits
  }

  @objc
  func openAbout(_ sender: NSMenuItem?) {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.orderFrontStandardAboutPanel(options: [NSApplication.AboutPanelOptionKey.credits: credits])
  }
}
