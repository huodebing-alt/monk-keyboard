import Carbon
import Foundation

// monk-register: tell Text Input Services about a freshly copied Monk.app so
// it appears in System Settings immediately, without waiting for a re-login.
let path = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : NSHomeDirectory() + "/Library/Input Methods/Monk.app"
let status = TISRegisterInputSource(URL(fileURLWithPath: path) as CFURL)
if status == noErr {
    print("Monk registered with the text input system.")
} else {
    print("Registration returned \(status); a log out / log in will register it instead.")
}
