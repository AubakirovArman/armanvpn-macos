import Darwin
import Foundation

guard geteuid() == 0 else { fputs("Cooling helper requires its approved system service.\n", stderr); exit(1) }
let origin = ContinuousClock.now
func now() -> Double {
    let value = origin.duration(to: .now).components
    return Double(value.seconds) + Double(value.attoseconds) / 1e18
}

do {
    let hardware = try SMCCoolingHardware()
    // A launchd restart restores only hardware previously owned by this helper.
    try hardware.recoverIfNeeded()
    let engine = CoolingEngine(hardware: hardware)
    let queue = DispatchQueue(label: "armanvpn.cooling.watchdog")
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler { engine.tick(now: now()) }
    timer.resume()

    let signals = [SIGTERM, SIGINT].map { signalNumber -> any DispatchSourceSignal in
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
        source.setEventHandler {
            do { try engine.shutdown(); unlink(CoolingIPC.socketPath); exit(0) }
            catch { fputs("Cooling reset will be retried by launchd.\n", stderr); exit(1) }
        }
        source.resume(); return source
    }
    withExtendedLifetime((timer, signals)) {
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { exit(1) }
        var metadata = stat()
        if lstat(CoolingIPC.socketPath, &metadata) == 0 {
            guard metadata.st_uid == 0, metadata.st_mode & S_IFMT == S_IFSOCK else { exit(1) }
            unlink(CoolingIPC.socketPath)
        }
        var address = CoolingIPC.address()
        umask(0o077)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(CoolingIPC.socketPath, 0o666) == 0, listen(listener, 16) == 0 else { exit(1) }
        while true {
            let fd = accept(listener, nil, nil)
            if fd < 0 { if errno == EINTR { continue }; exit(1) }
            defer { close(fd) }
            CoolingIPC.configure(fd, timeout: 2)
            do {
                var uid: uid_t = 0, gid: gid_t = 0, console = stat()
                guard getpeereid(fd, &uid, &gid) == 0, stat("/dev/console", &console) == 0,
                      uid >= 500, uid == console.st_uid else { continue }
                try CoolingIPC.verifyPeer(fd, identifier: CoolingIPC.appIdentifier)
                let request = try JSONDecoder().decode(CoolingRequest.self, from: CoolingIPC.receive(from: fd))
                let status = try engine.handle(request, now: now())
                try CoolingIPC.send(JSONEncoder().encode(CoolingReply(status: status)), to: fd)
            } catch {
                try? CoolingIPC.send(JSONEncoder().encode(CoolingReply(error: error.localizedDescription)), to: fd)
            }
        }
    }
} catch {
    // No addresses, credentials or SMC payloads are written to daemon logs.
    fputs("Cooling service could not initialize or recover.\n", stderr)
    exit(1)
}
