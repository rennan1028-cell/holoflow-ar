import Foundation

/// Lê o fluxo ao vivo do holoflow_server.py (Server-Sent Events em /stream).
/// Cada mensagem "data: {...}" vira um dicionário entregue na thread principal.
final class StreamClient: NSObject, URLSessionDataDelegate {
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var stopped = false
    private var url: URL?
    var onMessage: (([String: Any]) -> Void)?
    var onState: ((Bool, String) -> Void)?

    func connect(host: String, port: Int) {
        disconnect()
        stopped = false
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty, let u = URL(string: "http://\(h):\(port)/stream") else {
            onState?(false, "TOQUE EM ⚙︎ E DIGITE O IP DO SEU PC")
            return
        }
        url = u
        open()
    }

    private func open() {
        guard let u = url, !stopped else { return }
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60 * 60 * 24
        cfg.timeoutIntervalForResource = 60 * 60 * 24 * 7
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: OperationQueue())
        var req = URLRequest(url: u)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        buffer = Data()
        task = session?.dataTask(with: req)
        task?.resume()
        DispatchQueue.main.async { self.onState?(false, "CONECTANDO A \(u.host ?? "")…") }
    }

    func disconnect() {
        stopped = true
        task?.cancel()
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let ok = (response as? HTTPURLResponse)?.statusCode == 200
        DispatchQueue.main.async { self.onState?(ok, ok ? "CONECTADO AO PC" : "SERVIDOR RESPONDEU COM ERRO") }
        completionHandler(ok ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        let sep = Data("\n\n".utf8)
        while let r = buffer.range(of: sep) {
            let chunk = buffer.subdata(in: buffer.startIndex..<r.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<r.upperBound)
            guard let text = String(data: chunk, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where line.hasPrefix("data:") {
                let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if let d = json.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    DispatchQueue.main.async { self.onMessage?(obj) }
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !stopped else { return }
        DispatchQueue.main.async {
            self.onState?(false, "SEM CONEXÃO COM O PC · rode: python holoflow_server.py --lan")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.open() }
    }
}
