import Foundation
import AppKit

final class Window: NSWindow
{
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        
        isMovable = false
        backgroundColor = .clear
        ignoresMouseEvents = false
    }
}
