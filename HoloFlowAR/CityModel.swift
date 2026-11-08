import Foundation
import Combine

/// O livro de ofertas do MNQ transformado na grade da cidade (colunas = preço, ruas = tempo),
/// mais a tendência e a projeção dos próximos 15 s com placar real.
/// Mesma lógica da versão web. Nada é inventado: sem dado do PC, nada se move.
final class CityModel: ObservableObject {
    static let N = 48          // colunas de preço (1 tick = 0,25 cada)
    static let T = 36          // ruas guardadas (passado)
    let tick = 0.25
    let whaleQty = 40.0        // contratos

    // livro atual e memória dos níveis que saíram da tela
    private(set) var bids: [Double: Double] = [:]
    private(set) var asks: [Double: Double] = [:]
    private var mem: [Double: (q: Double, bid: Bool, t: Date)] = [:]

    // a cidade
    var gridB = [[Float]](repeating: [Float](repeating: 0, count: CityModel.N), count: CityModel.T)
    var gridA = [[Float]](repeating: [Float](repeating: 0, count: CityModel.N), count: CityModel.T)
    var rowBase = [Int](repeating: 0, count: CityModel.T)
    var rowMid = [Double](repeating: 0, count: CityModel.T)
    var rowValid = [Bool](repeating: false, count: CityModel.T)
    var head = 0
    var P0 = 0.0
    private var hasP0 = false
    private var qref = 0.0
    var midB = 0.0
    var midBs = 0.0            // suavizado, usado pelo desenho

    // fluxo
    private var trades: [(t: Date, q: Double, buy: Bool)] = []
    private var midHist: [(t: Date, m: Double)] = []
    private var preds: [(t: Date, m: Double, s: Double)] = []
    private var results: [Int] = []
    private var lastPred = Date.distantPast
    private(set) var gotBook = false
    private(set) var bestBid = 0.0, bestAsk = 0.0, mid = 0.0

    // o que a tela mostra
    @Published var price: Double = 0
    @Published var status = "CONECTANDO…"
    @Published var live = false
    @Published var trend: Double = 0             // -1 queda … +1 alta
    @Published var projS: Double = 0             // força/direção da projeção
    @Published var projSig: Double = 1           // movimento típico de 15 s
    @Published var scoreText = "coletando placar…"
    @Published var scorePct: Int? = nil
    @Published var frozen = false
    @Published var tradesPerSec: Double = 0
    @Published var lastWhale: String = ""

    let whale = PassthroughSubject<(x: Double, buy: Bool, mag: Double), Never>()
    let tradeTick = PassthroughSubject<(x: Double, buy: Bool, q: Double), Never>()
    private(set) var lastAdvance = Date()
    let advanceEvery = 0.65
    private var timers: [Timer] = []

    init() {
        timers.append(Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.sample() })
        timers.append(Timer.scheduledTimer(withTimeInterval: advanceEvery, repeats: true) { [weak self] _ in self?.advance() })
        for t in timers { RunLoop.main.add(t, forMode: .common) }
        timers.append(Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.analyze() })
    }

    private func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let d = v as? Double { return d }
        if let s = v as? String { return Double(s) }
        return nil
    }

    // MARK: entrada de dados
    func apply(_ m: [String: Any]) {
        if let b = m["b"] as? [Any], let a = m["a"] as? [Any] {
            var nb: [Double: Double] = [:], na: [Double: Double] = [:]
            for x in b { if let r = x as? [Any], r.count >= 2, let p = num(r[0]), let q = num(r[1]), q > 0 { nb[p] = q } }
            for x in a { if let r = x as? [Any], r.count >= 2, let p = num(r[0]), let q = num(r[1]), q > 0 { na[p] = q } }
            bids = nb; asks = na
        }
        if let t = m["t"] as? [Any] {
            for x in t {
                guard let r = x as? [Any], r.count >= 3, let p = num(r[0]), let q = num(r[1]), let s = r[2] as? String else { continue }
                onTrade(price: p, qty: q, buy: s == "buy")
            }
        }
        let ninja = (m["ninja"] as? Bool) ?? false
        let atraso = num(m["atraso"])
        if !ninja { status = "NINJATRADER DESCONECTADO · aplique o HoloFlowBridge"; live = false }
        else if let a = atraso, a > 30 { status = "SEM EVENTOS HÁ \(Int(a)) s · MERCADO FECHADO?"; live = false }
        else { status = "NINJATRADER · AO VIVO · MNQ"; live = true }
    }

    func onTrade(price p: Double, qty: Double, buy: Bool) {
        guard !frozen else { return }
        price = p
        trades.append((Date(), qty, buy))
        if hasP0 { tradeTick.send(((p - P0) / tick - midBs, buy, qty)) }
        if qty >= whaleQty && hasP0 {
            let x = (p - P0) / tick - midBs
            whale.send((x, buy, min(3, qty / whaleQty)))
            lastWhale = "\(buy ? "▲ COMPRA" : "▼ VENDA") \(Int(qty)) ct @ \(String(format: "%.2f", p))"
        }
    }

    func clear() {
        for r in 0..<CityModel.T { gridB[r] = [Float](repeating: 0, count: CityModel.N); gridA[r] = gridB[r]; rowValid[r] = false }
        hasP0 = false; qref = 0; mem = [:]; midHist = []; preds = []; results = []; gotBook = false
    }

    // MARK: uma "rua" nova a partir do livro
    func sample() {
        guard !frozen, let bb = bids.keys.max(), let ba = asks.keys.min(), ba > bb else { return }
        bestBid = bb; bestAsk = ba; mid = (bb + ba) / 2
        if price == 0 { price = mid }
        if !hasP0 { P0 = (mid / tick).rounded() * tick; hasP0 = true; midBs = (mid - P0) / tick }
        midB = (mid - P0) / tick
        let base = Int(midB.rounded())
        let now = Date()

        // memória: o futuro só mostra ~10 níveis; os que saem ficam apagando em ~1 min
        for (p, q) in bids { mem[p] = (q, true, now) }
        for (p, q) in asks { mem[p] = (q, false, now) }
        var eb = bids, ea = asks
        for (p, m) in mem {
            let age = now.timeIntervalSince(m.t)
            if age > 180 || (m.bid && p >= ba) || (!m.bid && p <= bb) { mem[p] = nil; continue }
            if age < 0.15 { continue }
            let q = m.q * exp(-age / 60) * 0.85
            if m.bid, eb[p] == nil { eb[p] = q } else if !m.bid, ea[p] == nil { ea[p] = q }
        }
        let N = CityModel.N
        var bq = [Double](repeating: 0, count: N), aq = [Double](repeating: 0, count: N)
        for (p, q) in eb { let k = Int(((p - P0) / tick).rounded()) - base + N / 2; if k >= 0 && k < N { bq[k] += q } }
        for (p, q) in ea { let k = Int(((p - P0) / tick).rounded()) - base + N / 2; if k >= 0 && k < N { aq[k] += q } }
        let vals = (bq + aq).filter { $0 > 0 }.sorted()
        guard vals.count >= 4 else { return }
        let p96 = vals[min(vals.count - 1, Int(Double(vals.count) * 0.96))]
        qref = qref == 0 ? p96 : qref * 0.97 + p96 * 0.03
        let r = head
        for i in 0..<N {
            gridB[r][i] = bq[i] > 0 ? Float(min(1.6, pow(bq[i] / qref, 0.62) * 0.72)) : 0
            gridA[r][i] = aq[i] > 0 ? Float(min(1.6, pow(aq[i] / qref, 0.62) * 0.72)) : 0
        }
        rowBase[r] = base; rowMid[r] = midB; rowValid[r] = true
        gotBook = true
    }

    func advance() {
        guard !frozen, gotBook else { return }
        let nh = (head + 1) % CityModel.T
        gridB[nh] = gridB[head]; gridA[nh] = gridA[head]
        rowBase[nh] = rowBase[head]; rowMid[nh] = rowMid[head]; rowValid[nh] = true
        head = nh
        lastAdvance = Date()
    }

    // MARK: tendência + projeção de 15 s (probabilidade, conferida depois)
    private func midAt(_ t: Date) -> Double {
        for h in midHist.reversed() where h.t <= t { return h.m }
        return midHist.first?.m ?? mid
    }

    func analyze() {
        guard gotBook, mid > 0 else { return }
        let now = Date()
        midHist.append((now, mid))
        midHist.removeAll { now.timeIntervalSince($0.t) > 360 }
        trades.removeAll { now.timeIntervalSince($0.t) > 60 }
        tradesPerSec = Double(trades.filter { now.timeIntervalSince($0.t) < 5 }.count) / 5

        // desequilíbrio dos 5 melhores níveis de cada lado
        let B = bids.sorted { $0.key > $1.key }.prefix(5), A = asks.sorted { $0.key < $1.key }.prefix(5)
        var qb = 0.0, qa = 0.0
        for (i, x) in B.enumerated() { qb += x.value / (1 + Double(i) * 0.5) }
        for (i, x) in A.enumerated() { qa += x.value / (1 + Double(i) * 0.5) }
        let I = qb + qa > 0 ? (qb - qa) / (qb + qa) : 0
        // agressão dos últimos 10 s e do último minuto
        var fb = 0.0, fs = 0.0, b60 = 0.0, s60 = 0.0
        for t in trades {
            if t.buy { b60 += t.q } else { s60 += t.q }
            if now.timeIntervalSince(t.t) < 10 { if t.buy { fb += t.q } else { fs += t.q } }
        }
        let F = fb + fs > 0 ? (fb - fs) / (fb + fs) : 0
        // régua de volatilidade: movimento típico de 15 s
        var acc = 0.0, n = 0.0
        for k in 1...20 {
            let t1 = now.addingTimeInterval(-Double(k) * 15)
            if let first = midHist.first, t1 < first.t { break }
            acc += abs(midAt(t1.addingTimeInterval(15)) - midAt(t1)); n += 1
        }
        let sig = n > 0 ? max(tick, acc / n) : tick * 4
        let mo = (mid - midAt(now.addingTimeInterval(-10))) / sig
        let raw = max(-1, min(1, 0.45 * I + 0.4 * F + 0.15 * tanh(mo)))
        projS += (raw - projS) * 0.35
        projSig = sig
        let r60 = (mid - midAt(now.addingTimeInterval(-60))) / (sig * 2.2)
        let fl = b60 + s60 > 0 ? (b60 - s60) / (b60 + s60) : 0
        let tr = tanh(0.7 * r60 + 0.6 * fl)
        trend += (tr - trend) * 0.2

        // placar: uma previsão por segundo, conferida 15 s depois
        if !frozen, now.timeIntervalSince(lastPred) >= 1 { lastPred = now; preds.append((now, mid, projS)) }
        while let p = preds.first, now.timeIntervalSince(p.t) >= 15 {
            preds.removeFirst()
            let mv = mid - p.m
            if abs(p.s) >= 0.2 && abs(mv) >= tick {
                results.append((mv > 0) == (p.s > 0) ? 1 : 0)
                if results.count > 300 { results.removeFirst() }
            }
        }
        if results.count < 30 { scoreText = "coletando placar… \(results.count)/30"; scorePct = nil }
        else {
            let pct = Int((Double(results.reduce(0, +)) / Double(results.count) * 100).rounded())
            scorePct = pct
            scoreText = "acertou \(pct)% das últimas \(results.count) · moeda = 50%"
        }
    }
}
