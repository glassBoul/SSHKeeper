import Foundation
import SSHKeeperCore

@main
enum SSHKeeperEntry {
    static func main() {
        if AskpassMain.isAskpassInvocation {
            AskpassMain.run()
        }
        SSHKeeperApp.main()
    }
}
