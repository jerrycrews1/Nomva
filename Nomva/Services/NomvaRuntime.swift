import Foundation

enum NomvaRuntime {
    static var isAutomatedTest: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.arguments.contains("-NomvaUITesting")
        #else
        false
        #endif
    }
}
