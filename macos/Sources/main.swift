import Cocoa
import InputMethodKit

/// Globals the controller reaches for.
enum CompApp {
    static var server: IMKServer?
    static var candidatesPanel: IMKCandidates?
}

autoreleasepool {
    guard let connectionName = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String,
          let identifier = Bundle.main.bundleIdentifier else {
        NSLog("Comp: missing bundle configuration")
        exit(1)
    }
    guard let server = IMKServer(name: connectionName, bundleIdentifier: identifier) else {
        NSLog("Comp: could not create IMKServer")
        exit(1)
    }
    CompApp.server = server
    CompApp.candidatesPanel = IMKCandidates(
        server: server,
        panelType: kIMKSingleRowSteppingCandidatePanel
    )
    NSLog("Comp input method started (%@)", connectionName)
    NSApplication.shared.run()
}
