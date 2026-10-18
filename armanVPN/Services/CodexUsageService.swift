import Darwin
import Foundation

enum CodexUsageService {
    static func locateExecutable(customPath: String = "") -> URL? {
        let candidates = [customPath,
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path]
        let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        return (candidates + pathCandidates).first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    static func fetch(executable: URL, timeout: TimeInterval = 20) throws -> CodexUsageSnapshot {
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? output.fileHandleForReading.close()
        }
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()

        func send(_ value: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: value)
            data.append(10)
            do { try input.fileHandleForWriting.write(contentsOf: data) }
            catch { throw VPNError.message("Codex закрыл соединение до получения лимитов. Попробуйте обновить Codex.") }
        }

        func receive(id: Int) throws -> [String: Any] {
            while Date() < deadline {
                if Task<Never, Never>.isCancelled { throw CancellationError() }
                while let end = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<end])
                    buffer.removeSubrange(...end)
                    guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          message["id"] as? Int == id else { continue }
                    if let error = message["error"] as? [String: Any] {
                        let code = error["code"] as? Int
                        throw VPNError.message(code == -32601
                            ? "Эта версия Codex не поддерживает чтение лимитов. Обновите Codex."
                            : "Codex не передал лимиты. Проверьте вход в аккаунт ChatGPT в Codex.")
                    }
                    guard let result = message["result"] as? [String: Any] else { throw VPNError.message("Неизвестный ответ Codex.") }
                    return result
                }
                var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&descriptor, 1, 200)
                if ready < 0 { if errno == EINTR { continue }; throw VPNError.message("Не удалось прочитать ответ Codex.") }
                if ready == 0 { continue }
                var bytes = [UInt8](repeating: 0, count: 8192)
                let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
                guard count > 0 else { throw VPNError.message("Codex завершился до получения лимитов. Проверьте его настройки и вход в аккаунт.") }
                buffer.append(contentsOf: bytes.prefix(count))
                guard buffer.count <= 1_048_576 else { throw VPNError.message("Ответ Codex превышает допустимый размер.") }
            }
            throw VPNError.message("Codex не ответил за \(Int(timeout)) секунд. Можно повторить обновление.")
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "armanvpn_usage", "title": "armanVPN", "version": "1.4"]]])
        _ = try receive(id: 1)
        try send(["method": "initialized"])
        try send(["id": 2, "method": "account/rateLimits/read"])
        let data = try JSONSerialization.data(withJSONObject: receive(id: 2))
        return try JSONDecoder().decode(CodexUsageSnapshot.self, from: data)
    }
}
