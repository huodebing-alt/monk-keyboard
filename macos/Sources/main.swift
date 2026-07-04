import Cocoa
import InputMethodKit

/// Globals the controller reaches for.
enum MonkApp {
    static var server: IMKServer?
    static var candidatesPanel: IMKCandidates?
}

autoreleasepool {
    guard let connectionName = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String,
          let identifier = Bundle.main.bundleIdentifier else {
        NSLog("Monk: missing bundle configuration")
        exit(1)
    }
    guard let server = IMKServer(name: connectionName, bundleIdentifier: identifier) else {
        NSLog("Monk: could not create IMKServer")
        exit(1)
    }
    MonkApp.server = server
    MonkApp.candidatesPanel = IMKCandidates(
        server: server,
        panelType: kIMKSingleRowSteppingCandidatePanel
    )
    if MonkInputController.flowMode {
        MonkInputController.llm?.preload()   // flow mode needs the LM warm
    }
    NSLog("Monk input method started (%@)", connectionName)
    NSApplication.shared.run()
}
