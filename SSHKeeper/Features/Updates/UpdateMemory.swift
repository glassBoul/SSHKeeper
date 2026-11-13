import Foundation

/// 持久化用户对版本更新的偏好：当前只记一个"跳过的版本号"。
/// 用户在更新弹窗点"跳过此版本" → 写入；启动检查命中相同 latest 时不再弹（菜单手动触发仍弹）。
enum UpdateMemory {
    private static let skippedVersionKey = "updateSkippedVersion.v1"

    static var skippedVersion: String? {
        get { UserDefaults.standard.string(forKey: skippedVersionKey) }
        set {
            if let v = newValue {
                UserDefaults.standard.set(v, forKey: skippedVersionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: skippedVersionKey)
            }
        }
    }
}
