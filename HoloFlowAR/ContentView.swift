import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: CityModel
    @StateObject private var ar = ARController()
    @State private var stream = StreamClient()
    @AppStorage("pcHost") private var host: String = ""
    @AppStorage("pcPort") private var port: Int = 8030
    @State private var showSettings = false
    @State private var intro = true

    private let cyan = Color(red: 0, green: 0.9, blue: 1)
    private let mag = Color(red: 1, green: 0.17, blue: 0.84)
    private let gold = Color(red: 1, green: 0.82, blue: 0.4)
    private let green = Color(red: 0.36, green: 1, blue: 0.63)
    private let red = Color(red: 1, green: 0.38, blue: 0.44)

    var body: some View {
        ZStack {
            ARViewContainer(controller: ar).ignoresSafeArea()

            // o mundo fica verde na alta e vermelho na queda (bordas da tela)
            RadialGradient(colors: [.clear, (model.trend >= 0 ? green : red).opacity(min(0.5, abs(model.trend) * 0.55))],
                           center: .center, startRadius: 170, endRadius: 560)
                .ignoresSafeArea().allowsHitTesting(false)
                .animation(.easeInOut(duration: 1.2), value: model.trend)
            CornerBrackets(color: cyan.opacity(0.7)).ignoresSafeArea().allowsHitTesting(false)

            VStack(spacing: 10) {
                topBar
                Spacer()
                if !ar.placed { placementHint } else if !model.lastWhale.isEmpty { whaleTag }
                if ar.placed { projectionPanel }
                bottomBar
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            if intro { IntroView(cyan: cyan, mag: mag).transition(.opacity) }
        }
        .onAppear {
            ar.attach(model)
            stream.onMessage = { m in model.apply(m) }
            stream.onState = { ok, txt in if !ok { model.status = txt; model.live = false } }
            if !host.isEmpty { stream.connect(host: host, port: port) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                withAnimation(.easeOut(duration: 0.8)) { intro = false }
                if host.isEmpty { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { showSettings = true } }
            }
        }
        .sheet(isPresented: $showSettings) { settings }
    }

    // MARK: topo
    private var topBar: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("HOLOFLOW").font(.system(size: 19, weight: .black, design: .monospaced)).tracking(4)
                    .foregroundStyle(LinearGradient(colors: [cyan, .white, mag], startPoint: .leading, endPoint: .trailing))
                    .shadow(color: cyan.opacity(0.7), radius: 8)
                HStack(spacing: 6) {
                    Circle().fill(model.live ? green : red).frame(width: 7, height: 7).shadow(color: model.live ? green : red, radius: 4)
                    Text(model.status).font(.system(size: 9.5, weight: .bold, design: .monospaced)).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                }
                Text(model.trend > 0.15 ? "▲ FLUXO COMPRADOR" : model.trend < -0.15 ? "▼ FLUXO VENDEDOR" : "◆ EQUILÍBRIO")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced)).tracking(1.5)
                    .foregroundStyle(model.trend > 0.15 ? green : model.trend < -0.15 ? red : .gray)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background((model.trend > 0.15 ? green : model.trend < -0.15 ? red : .gray).opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(model.trend > 0.15 ? green : model.trend < -0.15 ? red : .gray.opacity(0.5)))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("MNQ · NASDAQ MICRO").font(.system(size: 8.5, weight: .bold, design: .monospaced)).tracking(1.5).foregroundStyle(.white.opacity(0.6))
                Text(model.price > 0 ? String(format: "%.2f", model.price) : "—")
                    .font(.system(size: 28, weight: .heavy, design: .monospaced)).foregroundStyle(.white)
                    .shadow(color: .white.opacity(0.4), radius: 6)
                    .contentTransition(.numericText()).animation(.snappy, value: model.price)
                Text(String(format: "%.1f negócios/s", model.tradesPerSec)).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(cyan.opacity(0.8))
            }
            .padding(10).background(.black.opacity(0.55))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(cyan.opacity(0.35)))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: antes de colocar
    private var placementHint: some View {
        VStack(spacing: 10) {
            Text(ar.aiming ? "O CONTORNO MOSTRA ONDE A CIDADE VAI NASCER" : "MOVA O CELULAR DEVAGAR SOBRE A SUPERFÍCIE")
                .font(.system(size: 12, weight: .heavy, design: .monospaced)).foregroundStyle(cyan).multilineTextAlignment(.center)
            if ar.aiming {
                Button { ar.placeAtCenter() } label: {
                    Text("◎  COLOCAR AQUI").font(.system(size: 15, weight: .black, design: .monospaced)).tracking(2)
                        .foregroundStyle(.black).padding(.horizontal, 26).padding(.vertical, 13)
                        .background(LinearGradient(colors: [cyan, .white], startPoint: .leading, endPoint: .trailing))
                        .clipShape(RoundedRectangle(cornerRadius: 10)).shadow(color: cyan, radius: 14)
                }
                Text("ou toque direto na superfície").font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
            }
            sizePicker
        }
        .padding(14).background(.black.opacity(0.55)).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var sizePicker: some View {
        HStack(spacing: 6) {
            ForEach(["MESA", "CHÃO", "GIGANTE"], id: \.self) { n in
                Button { ar.setSize(n) } label: {
                    VStack(spacing: 1) {
                        Text(n).font(.system(size: 11, weight: .heavy, design: .monospaced))
                        Text(n == "MESA" ? "45 cm" : (n == "CHÃO" ? "1,8 m" : "4,5 m")).font(.system(size: 8.5, design: .monospaced)).opacity(0.7)
                    }
                    .foregroundStyle(ar.sizeName == n ? Color.black : Color.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .background(ar.sizeName == n ? AnyShapeStyle(gold) : AnyShapeStyle(Color.black.opacity(0.4)))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(gold.opacity(0.6)))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }
            }
        }
    }

    private var whaleTag: some View {
        Text("🐋 " + model.lastWhale).font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundStyle(.white).padding(8).background(.black.opacity(0.55)).clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: projeção
    private var projectionPanel: some View {
        let s = model.projS, dir = s > 0.2 ? 1 : (s < -0.2 ? -1 : 0)
        let col = dir > 0 ? green : (dir < 0 ? red : gold)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("◎ PROJEÇÃO 15 s").font(.system(size: 10, weight: .heavy, design: .monospaced)).tracking(1.5).foregroundStyle(cyan)
                Spacer()
                Text("probabilidade").font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
            }
            HStack(spacing: 10) {
                Text(dir > 0 ? "▲" : dir < 0 ? "▼" : "◆").font(.system(size: 26, weight: .black)).foregroundStyle(col).shadow(color: col, radius: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(dir > 0 ? "ALTA PROVÁVEL" : dir < 0 ? "QUEDA PROVÁVEL" : "SEM DIREÇÃO CLARA")
                        .font(.system(size: 14, weight: .black, design: .monospaced)).foregroundStyle(col)
                    Text(String(format: "força %d%% · alvo ≈ %.2f", Int(abs(s) * 100), model.price + s * model.projSig))
                        .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.white.opacity(0.75))
                }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.1))
                    Rectangle().fill(col).frame(width: g.size.width * CGFloat(min(1, abs(s)))).shadow(color: col, radius: 4)
                }
            }.frame(height: 4)
            Text(model.scoreText).font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(model.scorePct.map { $0 >= 55 ? green : ($0 >= 50 ? gold : red) } ?? .white.opacity(0.6))
        }
        .padding(10).background(.black.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(col.opacity(0.55)))
        .animation(.easeOut(duration: 0.3), value: dir)
    }

    // MARK: botões
    private var bottomBar: some View {
        VStack(spacing: 8) {
            if ar.placed { sizePicker }
            HStack(spacing: 8) {
                pill(model.frozen ? "▶ AO VIVO" : "❄ CONGELAR") { model.frozen.toggle() }
                pill("⟲ MUDAR LUGAR") { ar.reposition() }
                pill("⚙︎ PC") { showSettings = true }
            }
        }
    }

    private func pill(_ t: String, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Text(t).font(.system(size: 11.5, weight: .heavy, design: .monospaced)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .background(.black.opacity(0.55)).overlay(RoundedRectangle(cornerRadius: 8).stroke(cyan.opacity(0.5)))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: configuração do PC
    private var settings: some View {
        NavigationStack {
            Form {
                Section(header: Text("Servidor no seu PC"),
                        footer: Text("No PC rode:  python holoflow_server.py --lan\nO endereço aparece no cmd (ex.: 192.168.1.20). Celular e PC na mesma rede Wi-Fi.")) {
                    TextField("IP do PC (ex.: 192.168.1.20)", text: $host).keyboardType(.decimalPad).autocorrectionDisabled()
                    Stepper("Porta: \(port)", value: $port, in: 1...65535)
                }
                Section {
                    Button("Conectar") { model.clear(); stream.connect(host: host, port: port); showSettings = false }
                }
                Section(header: Text("Como usar")) {
                    Text("1. Aponte para a mesa ou o chão e mova devagar.\n2. O contorno azul mostra onde a cidade vai nascer: toque em COLOCAR AQUI.\n3. Um dedo arrasta · dois dedos giram · pinça aumenta.\n4. MESA / CHÃO / GIGANTE mudam o tamanho. No GIGANTE dá para andar dentro.\n5. Ande em volta e chegue perto: ela fica presa no lugar.")
                        .font(.footnote)
                }
            }
            .navigationTitle("HOLOFLOW")
        }
    }
}

/// cantoneiras de mira nos cantos da tela
struct CornerBrackets: View {
    let color: Color
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height, L: CGFloat = 26, m: CGFloat = 10
            Path { p in
                p.move(to: CGPoint(x: m, y: m + L)); p.addLine(to: CGPoint(x: m, y: m)); p.addLine(to: CGPoint(x: m + L, y: m))
                p.move(to: CGPoint(x: w - m - L, y: m)); p.addLine(to: CGPoint(x: w - m, y: m)); p.addLine(to: CGPoint(x: w - m, y: m + L))
                p.move(to: CGPoint(x: m, y: h - m - L)); p.addLine(to: CGPoint(x: m, y: h - m)); p.addLine(to: CGPoint(x: m + L, y: h - m))
                p.move(to: CGPoint(x: w - m - L, y: h - m)); p.addLine(to: CGPoint(x: w - m, y: h - m)); p.addLine(to: CGPoint(x: w - m, y: h - m - L))
            }
            .stroke(color, lineWidth: 2)
        }
    }
}

/// abertura: losangos girando, letras surgindo, varredura de luz
struct IntroView: View {
    let cyan: Color, mag: Color
    @State private var spin = false
    @State private var show = false
    @State private var scan: CGFloat = -1
    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            RadialGradient(colors: [cyan.opacity(0.25), .clear], center: .center, startRadius: 10, endRadius: 360).ignoresSafeArea()
            VStack(spacing: 22) {
                ZStack {
                    Rectangle().stroke(cyan, lineWidth: 3).frame(width: 74, height: 74).rotationEffect(.degrees(spin ? 405 : 45)).shadow(color: cyan, radius: 12)
                    Rectangle().stroke(mag, lineWidth: 3).frame(width: 40, height: 40).rotationEffect(.degrees(spin ? -315 : 45)).shadow(color: mag, radius: 12)
                    Circle().fill(.white).frame(width: 9, height: 9).shadow(color: .white, radius: 8)
                }
                Text("HOLOFLOW").font(.system(size: 40, weight: .black, design: .monospaced)).tracking(show ? 10 : 30)
                    .foregroundStyle(LinearGradient(colors: [cyan, .white, mag], startPoint: .leading, endPoint: .trailing))
                    .shadow(color: cyan.opacity(0.8), radius: 16).opacity(show ? 1 : 0).blur(radius: show ? 0 : 12)
                Text("A LIQUIDEZ DO MERCADO, NA SUA MESA").font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(3)
                    .foregroundStyle(cyan).opacity(show ? 1 : 0)
            }
            GeometryReader { g in
                Rectangle().fill(LinearGradient(colors: [.clear, cyan.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                    .frame(height: 120).offset(y: scan * g.size.height)
            }.ignoresSafeArea().allowsHitTesting(false)
        }
        .onAppear {
            withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { spin = true }
            withAnimation(.easeOut(duration: 1.1).delay(0.2)) { show = true }
            withAnimation(.easeInOut(duration: 2.2)) { scan = 1.1 }
        }
    }
}
