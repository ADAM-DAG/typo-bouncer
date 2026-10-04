import Foundation

struct AppInstance {
    let pid: Int32
    let launched: Date
}

enum SingleInstancePolicy {
    // Both copies make the same decision even if launched almost simultaneously.
    static func existingInstance(current: AppInstance, peers: [AppInstance]) -> AppInstance? {
        let first = ([current] + peers).min {
            $0.launched == $1.launched ? $0.pid < $1.pid : $0.launched < $1.launched
        }
        return first?.pid == current.pid ? nil : first
    }
}
