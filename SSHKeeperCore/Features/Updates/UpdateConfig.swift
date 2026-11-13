import Foundation

/// 版本更新相关配置常量。集中放此处便于将来改 host / 调时长。
public enum UpdateConfig {
    /// 远端 version.json URL（与 DMG 同目录托管）。
    public static let manifestURL: URL = URL(string: "https://sshkeeper.feilian.cc/version.json")!
    /// App 启动后延迟多久才发起检查（秒），避免阻塞冷启动。
    public static let launchCheckDelay: TimeInterval = 3.0
    /// URLSession 请求超时（秒）。
    public static let fetchTimeout: TimeInterval = 8.0
}
