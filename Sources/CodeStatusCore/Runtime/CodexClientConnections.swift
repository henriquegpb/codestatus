import Foundation

/// Opaque kernel socket handles only. No addresses, traffic, arguments, or
/// environment values are needed to recognise a terminal client of a daemon.
struct UnixSocketConnection: Sendable, Equatable {
    let socket: UInt64
    let peer: UInt64
}

enum CodexClientConnections {
    static func clientPIDs(
        services: Set<pid_t>,
        sockets: [pid_t: [UnixSocketConnection]]
    ) -> Set<pid_t> {
        let serviceSockets = Set(services.flatMap { sockets[$0] ?? [] }
            .map(\.socket).filter { $0 != 0 })
        return Set(sockets.compactMap { pid, connections in
            guard !services.contains(pid), connections.contains(where: {
                $0.peer != 0 && serviceSockets.contains($0.peer)
            }) else { return nil }
            return pid
        })
    }
}
