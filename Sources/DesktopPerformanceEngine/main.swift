import AppKit

// Bootstrap a regular AppKit app without a storyboard/xib.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
