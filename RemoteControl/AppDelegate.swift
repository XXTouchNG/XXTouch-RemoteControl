import Cocoa

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Insert code here to initialize your application
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return false
    }
    
    func menuNeedsUpdate(_ menu: NSMenu) {
        if let window = NSApp.mainWindow,
           let titleBarStyleItem = menu.items.filter({ $0.identifier?.rawValue == "UseTransparentTitleBar" }).first {
            titleBarStyleItem.state = window.titlebarAppearsTransparent ? .on : .off
        }
    }
}

