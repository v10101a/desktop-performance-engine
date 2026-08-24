import DPECore
import Foundation

// Real exit code: CI can gate on this, unlike the app's NSLog --test-* modes.
exit(Int32(min(UnitTests.runAll(), 125)))
