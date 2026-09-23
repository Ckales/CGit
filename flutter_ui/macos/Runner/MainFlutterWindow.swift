import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()

    // After super, not before: assigning contentViewController resizes the
    // window to what the Flutter view asks for, which is why the template
    // re-applies the nib's frame on the line right after it.
    //
    // macOS then restores the size from the last session on top of this, so
    // 1280×820 is only what a fresh install opens at — the same geometry
    // tauri.conf.json declares for the other frontend. The minimum is the part
    // that always applies, and it is the one that matters: the toolbar is a
    // fixed row of buttons, and below this width Flutter draws a striped
    // overflow band rather than reflowing.
    self.contentMinSize = NSSize(width: 900, height: 600)
    self.setContentSize(NSSize(width: 1280, height: 820))
    self.center()
  }
}
