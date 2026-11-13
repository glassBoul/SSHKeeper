import Foundation
import OSLog

/// When SSHKeeper is launched as an SSH_ASKPASS helper (env var triggers it,
/// since SSH_ASKPASS doesn't pass our own argv), this entry point reads the
/// password from Keychain and writes it to stdout, then exits.
public enum AskpassMain {
    public static let triggerEnvVar = "SSHKEEPER_ASKPASS"
    public static let aliasEnvVar = "SSHKEEPER_ASKPASS_ALIAS"

    private static let log = Logger(subsystem: "com.sshkeeper.app", category: "askpass")

    /// Returns true if the current process is an askpass invocation.
    public static var isAskpassInvocation: Bool {
        ProcessInfo.processInfo.environment[triggerEnvVar] == "1"
    }

    /// Run the askpass flow. Exits the process; never returns.
    ///
    /// 日志脱敏原则：alias 是 App 自己生成的稳定标识，可作为关联 key 公开；
    /// 但 ssh 调起 askpass 时传入的 argv（含 prompt 路径/用户）和密码任何属性
    /// （含长度）都视为机密，全部 .private，避免进 Console / sysdiagnose。
    public static func run() -> Never {
        let env = ProcessInfo.processInfo.environment
        let alias = env[aliasEnvVar] ?? ""
        log.info("askpass invoked alias=\(alias, privacy: .public) argc=\(CommandLine.arguments.count, privacy: .public)")

        guard !alias.isEmpty else {
            log.error("missing \(aliasEnvVar, privacy: .public) env var")
            FileHandle.standardError.write(Data("SSHKeeper askpass: missing \(aliasEnvVar)\n".utf8))
            exit(1)
        }
        guard let password = PasswordKeychain.read(alias: alias) else {
            log.error("no password in keychain for alias=\(alias, privacy: .public)")
            FileHandle.standardError.write(Data("SSHKeeper askpass: no password in keychain for \(alias)\n".utf8))
            exit(1)
        }
        log.info("askpass delivered password for alias=\(alias, privacy: .public)")
        FileHandle.standardOutput.write(Data((password + "\n").utf8))
        exit(0)
    }
}
