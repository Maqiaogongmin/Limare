import Foundation
func AppLocalized(_ value: String) -> String { value }
/// Protocol diagnostics contain no request bodies or credentials. The host supplies the sink.
public enum NativeProtocolDiagnostics {
    @TaskLocal public static var sink: (@Sendable (String, String) -> Void)?
}
struct AppLogger {
    private let category: String
    init(category: String) { self.category = category }
    init(subsystem: String, category: String) { self.category = category }
    func info(_ s: String) { NativeProtocolDiagnostics.sink?(category, "info") }
    func debug(_ s: @autoclosure () -> String) { NativeProtocolDiagnostics.sink?(category, "debug") }
    func error(_ s: String) { NativeProtocolDiagnostics.sink?(category, "error") }
    func warning(_ s: String) { NativeProtocolDiagnostics.sink?(category, "warning") }
    func notice(_ s: String) { NativeProtocolDiagnostics.sink?(category, "notice") }
}
