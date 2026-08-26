import SwiftUI
import AppKit

// MARK: - Config
// Kisisel degerler config.json'dan gelir (bkz. config.example.json).
// Buradakiler yalnizca ilk acilis varsayilanidir - repoya sir girmemesi icin bostur.
struct DOAConfig: Codable {
    var phone: String = ""
    var email: String = ""
    var app_password: String = ""
    var lat: Double = 41.0082
    var lon: Double = 28.9784
    var distance: Int = 2000
    var userLat: Double = 41.0082
    var userLon: Double = 28.9784
    var morning_hours: [Int] = [7, 8, 9, 10, 11]
    var evening_hours: [Int] = [17, 18, 19, 20, 21]
    var check_minutes: [Int] = [0, 30]
    var random_delay_max: Int = 600
    var watch_materials: [String] = ["pet", "glass"]
    var full_threshold: Int = 90
    var enabled: Bool = true

    static let configPath = NSHomeDirectory() + "/doa-watcher/config.json"

    enum CodingKeys: String, CodingKey {
        case phone, email, app_password, lat, lon, distance, userLat, userLon
        case morning_hours, evening_hours, check_minutes, random_delay_max
        case watch_materials, full_threshold, enabled
    }

    init() {}

    // Eksik anahtarlar varsayilan degere duser (ileri/geri uyumluluk)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DOAConfig()
        phone = try c.decodeIfPresent(String.self, forKey: .phone) ?? d.phone
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? d.email
        app_password = try c.decodeIfPresent(String.self, forKey: .app_password) ?? d.app_password
        lat = try c.decodeIfPresent(Double.self, forKey: .lat) ?? d.lat
        lon = try c.decodeIfPresent(Double.self, forKey: .lon) ?? d.lon
        distance = try c.decodeIfPresent(Int.self, forKey: .distance) ?? d.distance
        userLat = try c.decodeIfPresent(Double.self, forKey: .userLat) ?? d.userLat
        userLon = try c.decodeIfPresent(Double.self, forKey: .userLon) ?? d.userLon
        morning_hours = try c.decodeIfPresent([Int].self, forKey: .morning_hours) ?? d.morning_hours
        evening_hours = try c.decodeIfPresent([Int].self, forKey: .evening_hours) ?? d.evening_hours
        check_minutes = try c.decodeIfPresent([Int].self, forKey: .check_minutes) ?? d.check_minutes
        random_delay_max = try c.decodeIfPresent(Int.self, forKey: .random_delay_max) ?? d.random_delay_max
        watch_materials = try c.decodeIfPresent([String].self, forKey: .watch_materials) ?? d.watch_materials
        full_threshold = try c.decodeIfPresent(Int.self, forKey: .full_threshold) ?? d.full_threshold
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
    }

    static func load() -> DOAConfig {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let c = try? JSONDecoder().decode(DOAConfig.self, from: data)
        else { return DOAConfig() }
        return c
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(self) else { return }
        try? data.write(to: URL(fileURLWithPath: Self.configPath))
    }
}
// MARK: - Log Adimi
struct LogStep: Identifiable {
    let id = UUID()
    let message: String
    let icon: String
    let color: Color
}

func parseLogStep(_ line: String) -> LogStep {
    var msg = line
    if let r = line.range(of: #"^\[[\d\- :]+\] "#, options: .regularExpression) {
        msg = String(line[r.upperBound...])
    }
    let lower = msg.lowercased()
    if lower.contains("basliyor") {
        return LogStep(message: msg, icon: "arrow.clockwise", color: .blue)
    }
    if lower.contains("gecikme") {
        return LogStep(message: msg, icon: "hourglass", color: .secondary)
    }
    if lower.contains("otp gonderiliyor") {
        return LogStep(message: msg, icon: "paperplane.fill", color: .orange)
    }
    if lower.contains("otp gonderildi") {
        return LogStep(message: msg, icon: "paperplane.circle.fill", color: .green)
    }
    if lower.contains("otp bekleniyor") {
        return LogStep(message: msg, icon: "clock.fill", color: .orange)
    }
    if lower.contains("otp deneme") {
        return LogStep(message: msg, icon: "arrow.clockwise", color: .orange)
    }
    if lower.contains("otp okundu") {
        return LogStep(message: msg, icon: "message.fill", color: .green)
    }
    if lower.contains("dogrulaniyor") {
        return LogStep(message: msg, icon: "lock.fill", color: .orange)
    }
    if lower.contains("token alindi") {
        return LogStep(message: msg, icon: "key.fill", color: .green)
    }
    if lower.contains("sorgulanyor") {
        return LogStep(message: msg, icon: "magnifyingglass", color: .blue)
    }
    if lower.contains("email gonderildi") || lower.contains("bildirimler gonderildi") {
        return LogStep(message: msg, icon: "envelope.fill", color: .green)
    }
    if lower.contains("macos bildirimi") {
        return LogStep(message: msg, icon: "bell.fill", color: .green)
    }
    if lower.contains("tamamlandi") {
        return LogStep(message: msg, icon: "checkmark.circle.fill", color: .green)
    }
    if lower.contains("hatasi") || lower.contains("basarisiz") || lower.contains("bulunamadi") || lower.contains("okunamadi") || lower.contains("gonderilemedi") {
        return LogStep(message: msg, icon: "xmark.circle.fill", color: .red)
    }
    if lower.contains("uygun makine yok") || lower.contains("atlaniyor") {
        return LogStep(message: msg, icon: "minus.circle", color: .orange)
    }
    if msg.hasPrefix("  ") {
        return LogStep(message: msg, icon: "desktopcomputer", color: .primary)
    }
    return LogStep(message: msg, icon: "circle.fill", color: .secondary)
}
// MARK: - Launchd Yonetimi
var plistPath: String { NSHomeDirectory() + "/Library/LaunchAgents/com.ozden.doa-watcher.plist" }
var plistDisabledPath: String { plistPath + ".disabled" }

@discardableResult
func runLaunchctl(_ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    let sink = Pipe()
    p.standardOutput = sink
    p.standardError = sink
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

// Zamanlayici su an launchd'ye kayitli mi?
func isSchedulerLoaded() -> Bool {
    return runLaunchctl(["list", "com.ozden.doa-watcher"]) == 0
}

func applySchedule(config: DOAConfig) {
    let home = NSHomeDirectory()
    let exec = home + "/doa-watcher/DOAWatcher.app/Contents/MacOS/DOAWatcher"
    var intervals = ""
    for hour in config.morning_hours + config.evening_hours {
        for minute in config.check_minutes {
            intervals += "        <dict><key>Hour</key><integer>\(hour)</integer><key>Minute</key><integer>\(minute)</integer></dict>\n"
        }
    }
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key><string>com.ozden.doa-watcher</string>
        <key>ProgramArguments</key>
        <array><string>\(exec)</string><string>--check</string></array>
        <key>StartCalendarInterval</key>
        <array>
    \(intervals)    </array>
        <key>StandardOutPath</key><string>\(home)/doa-watcher/logs/launchd-stdout.log</string>
        <key>StandardErrorPath</key><string>\(home)/doa-watcher/logs/launchd-stderr.log</string>
        <key>WorkingDirectory</key><string>\(home)/doa-watcher</string>
    </dict>
    </plist>
    """
    // Once mevcut kaydi kaldir
    runLaunchctl(["unload", plistPath])
    let fm = FileManager.default
    if config.enabled {
        // Aktif: plist'i yaz ve launchd'ye yukle
        try? fm.removeItem(atPath: plistDisabledPath)
        try? plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
        runLaunchctl(["load", "-w", plistPath])
    } else {
        // Kapali: plist'i .disabled olarak sakla, aktif konumdan cikar
        // (boylece yeniden baslatmada da otomatik yuklenmez)
        try? plist.write(toFile: plistDisabledPath, atomically: true, encoding: .utf8)
        try? fm.removeItem(atPath: plistPath)
    }
}

// Bir sonraki planli kontrolun zamani
func nextRunDescription(config: DOAConfig) -> String {
    if !config.enabled { return "Duraklatildi" }
    let hours = Array(Set(config.morning_hours + config.evening_hours)).sorted()
    let mins = Array(Set(config.check_minutes)).sorted()
    if hours.isEmpty || mins.isEmpty { return "Zamanlama tanimli degil" }
    let cal = Calendar.current
    let now = Date()
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "tr_TR")
    for dayOffset in 0...1 {
        guard let base = cal.date(byAdding: .day, value: dayOffset, to: now) else { continue }
        for h in hours {
            for m in mins {
                var comp = cal.dateComponents([.year, .month, .day], from: base)
                comp.hour = h; comp.minute = m; comp.second = 0
                if let d = cal.date(from: comp), d > now {
                    fmt.dateFormat = dayOffset == 0 ? "'bugun' HH:mm" : "'yarin' HH:mm"
                    return fmt.string(from: d)
                }
            }
        }
    }
    return "-"
}
// MARK: - Settings View
struct SettingsView: View {
    @State private var config = DOAConfig.load()
    @State private var statusMsg = ""
    @State private var statusOk = true
    @State private var isChecking = false
    @State private var logSteps: [LogStep] = []
    @State private var morningTxt: String = ""
    @State private var eveningTxt: String = ""
    @State private var minutesTxt: String = ""
    @State private var nextRunTxt: String = "-"
    @State private var ready = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Header
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 28))
                            .foregroundStyle(config.enabled ? .blue : .gray)
                        VStack(alignment: .leading) {
                            Text("DOA Watcher").font(.title.bold())
                            Text("Depozito iade makinesi takip sistemi")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    // Ana anahtar
                    GroupBox {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(config.enabled ? Color.green : Color.secondary.opacity(0.5))
                                .frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(config.enabled ? "Otomatik takip acik" : "Otomatik takip kapali")
                                    .font(.headline)
                                Text(config.enabled
                                     ? "Sonraki kontrol: \(nextRunTxt)"
                                     : "Zamanlanmis kontroller durduruldu")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $config.enabled)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .disabled(isChecking)
                                .onChange(of: config.enabled) {
                                    toggleScheduler()
                                }
                        }.padding(6)
                    }

                    Divider()
                    // Hesap
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Hesap", systemImage: "person.circle").font(.headline)
                            LabeledContent("Telefon") {
                                TextField("5XXXXXXXXX", text: $config.phone)
                                    .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                            }
                            LabeledContent("Email") {
                                TextField("email@gmail.com", text: $config.email)
                                    .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                            }
                            LabeledContent("Gmail App Sifresi") {
                                SecureField("xxxx xxxx xxxx xxxx", text: $config.app_password)
                                    .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                            }
                        }.padding(6)
                    }
                    // Konum
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label("Konum", systemImage: "location.circle").font(.headline)
                                Spacer()
                                Button(action: openMaps) {
                                    Label("Haritada Goster", systemImage: "map")
                                }.buttonStyle(.borderless).font(.caption)
                            }
                            Text("Makine aranacak merkez nokta. Google Maps'te bir noktaya sag tiklayip koordinatlari kopyalayabilirsiniz.")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 16) {
                                LabeledContent("Enlem") {
                                    TextField("41.0082", value: $config.lat, format: .number)
                                        .textFieldStyle(.roundedBorder).frame(width: 160)
                                }
                                LabeledContent("Boylam") {
                                    TextField("28.9784", value: $config.lon, format: .number)
                                        .textFieldStyle(.roundedBorder).frame(width: 160)
                                }
                            }
                            LabeledContent("Arama Yaricapi") {
                                HStack(spacing: 6) {
                                    TextField("2000", value: $config.distance, format: .number)
                                        .textFieldStyle(.roundedBorder).frame(width: 80)
                                    Text("metre").foregroundStyle(.secondary)
                                }
                            }
                            Text("Bu yaricap icindeki DOA makineleri aranir")
                                .font(.caption).foregroundStyle(.tertiary)
                        }.padding(6)
                    }
                    // Zamanlama
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Zamanlama", systemImage: "clock").font(.headline)
                            LabeledContent("Sabah Saatleri") {
                                TextField("7, 8, 9, 10, 11", text: $morningTxt)
                                    .textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                            }
                            LabeledContent("Aksam Saatleri") {
                                TextField("17, 18, 19, 20, 21", text: $eveningTxt)
                                    .textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                            }
                            LabeledContent("Dakikalar") {
                                TextField("0, 30", text: $minutesTxt)
                                    .textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                            }
                            LabeledContent("Maks. Gecikme") {
                                HStack(spacing: 6) {
                                    TextField("", value: $config.random_delay_max, format: .number)
                                        .textFieldStyle(.roundedBorder).frame(width: 80)
                                    Text("saniye").foregroundStyle(.secondary)
                                }
                            }
                            Text("Her kontrole 0-\(config.random_delay_max) sn rastgele gecikme eklenir (bot tespitini onler)")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(6)
                    }

                    // Bilgi notu
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                        Text("Zamanlanmis kontroller uygulama kapali olsa bile arka planda calisir. Uygulamayi acik tutmaniza gerek yok. Duraklatmak icin yukaridaki anahtari kapatin.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.horizontal, 4)
                    // Butonlar
                    HStack(spacing: 16) {
                        Button(action: doSave) {
                            Label("Kaydet", systemImage: "checkmark.circle.fill")
                        }.buttonStyle(.borderedProminent).disabled(isChecking)
                        Button(action: doCheck) {
                            if isChecking {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Simdi Kontrol Et", systemImage: "play.circle.fill")
                            }
                        }.buttonStyle(.bordered).disabled(isChecking)
                    }

                    // Durum mesaji
                    if !statusMsg.isEmpty && !isChecking && logSteps.isEmpty {
                        HStack {
                            Image(systemName: statusOk ? "checkmark.circle" : "xmark.circle")
                            Text(statusMsg)
                        }
                        .foregroundStyle(statusOk ? .green : .red).font(.callout)
                    }
                    // Ilerleme paneli
                    if isChecking || !logSteps.isEmpty {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    if isChecking {
                                        ProgressView().controlSize(.small).padding(.trailing, 2)
                                    }
                                    Label(isChecking ? "Kontrol devam ediyor..." : (statusOk ? "Kontrol Tamamlandi" : "Kontrol Basarisiz"),
                                          systemImage: isChecking ? "arrow.clockwise" : (statusOk ? "checkmark.circle" : "xmark.circle"))
                                        .font(.headline)
                                        .foregroundStyle(isChecking ? .blue : (statusOk ? .green : .red))
                                    Spacer()
                                    if !isChecking && !logSteps.isEmpty {
                                        Button(action: { logSteps = []; statusMsg = "" }) {
                                            Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                                        }.buttonStyle(.borderless)
                                    }
                                }
                                Divider()
                                ForEach(logSteps) { step in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: step.icon)
                                            .foregroundStyle(step.color)
                                            .frame(width: 18, alignment: .center)
                                        Text(step.message)
                                            .font(.system(.callout, design: .monospaced))
                                            .foregroundStyle(step.color == .secondary ? .secondary : .primary)
                                            .textSelection(.enabled)
                                    }
                                    .padding(.vertical, 1)
                                    .id(step.id)
                                }
                            }.padding(8)
                        }
                    }
                }.padding(24)
            }
            .onChange(of: logSteps.count) {
                if let last = logSteps.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(width: 560, height: 760)
        .onAppear {
            let c = config
            morningTxt = c.morning_hours.map(String.init).joined(separator: ", ")
            eveningTxt = c.evening_hours.map(String.init).joined(separator: ", ")
            minutesTxt = c.check_minutes.map(String.init).joined(separator: ", ")
            // config.json tek dogruluk kaynagidir.
            // launchd durumu ayardan farkliysa launchd'yi ayara uyduruyoruz -
            // tersini yapmak (ayari launchd'den okumak) gecici bir launchctl
            // hatasinda takibi sessizce kapatabilir.
            if c.enabled != isSchedulerLoaded() {
                applySchedule(config: c)
            }
            nextRunTxt = nextRunDescription(config: config)
            ready = true
        }
    }

    // Anahtar degistiginde aninda uygula (Kaydet'e basmaya gerek yok)
    func toggleScheduler() {
        guard ready else { return }
        applyCurrentFields()
        config.save()
        applySchedule(config: config)
        nextRunTxt = nextRunDescription(config: config)
        statusMsg = config.enabled
            ? "Otomatik takip acildi - sonraki kontrol: \(nextRunTxt)"
            : "Otomatik takip duraklatildi"
        statusOk = true
    }

    func applyCurrentFields() {
        config.morning_hours = morningTxt.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        config.evening_hours = eveningTxt.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        config.check_minutes = minutesTxt.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        config.userLat = config.lat
        config.userLon = config.lon
    }

    func doSave() {
        applyCurrentFields()
        config.save()
        applySchedule(config: config)
        nextRunTxt = nextRunDescription(config: config)
        statusMsg = config.enabled
            ? "Ayarlar kaydedildi - sonraki kontrol: \(nextRunTxt)"
            : "Ayarlar kaydedildi (otomatik takip kapali)"
        statusOk = true
    }

    func openMaps() {
        let url = "https://www.google.com/maps/@\(config.lat),\(config.lon),15z"
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
    func doCheck() {
        isChecking = true
        logSteps = []
        statusMsg = ""

        DispatchQueue.global(qos: .userInitiated).async {
            let home = NSHomeDirectory()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [home + "/doa-watcher/doa-checker.py", "--now"]
            p.currentDirectoryURL = URL(fileURLWithPath: home + "/doa-watcher")

            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe

            var buffer = ""
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                buffer += chunk
                while let nl = buffer.range(of: "\n") {
                    let line = String(buffer[buffer.startIndex..<nl.lowerBound])
                    buffer = String(buffer[nl.upperBound...])
                    if !line.isEmpty {
                        let step = parseLogStep(line)
                        DispatchQueue.main.async { logSteps.append(step) }
                    }
                }
            }
            do {
                try p.run()
                p.waitUntilExit()
            } catch {
                DispatchQueue.main.async {
                    logSteps.append(LogStep(message: "Hata: \(error.localizedDescription)", icon: "xmark.circle.fill", color: .red))
                }
            }

            if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let step = parseLogStep(buffer)
                DispatchQueue.main.async { logSteps.append(step) }
            }
            pipe.fileHandleForReading.readabilityHandler = nil

            DispatchQueue.main.async {
                isChecking = false
                let code = p.terminationStatus
                statusOk = code == 0
                statusMsg = code == 0 ? "Kontrol tamamlandi" : "Kontrol hatasi (kod: \(code))"
            }
        }
    }
}
// MARK: - App Entry
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--check") {
            let home = NSHomeDirectory()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [home + "/doa-watcher/doa-checker.py"]
            p.currentDirectoryURL = URL(fileURLWithPath: home + "/doa-watcher")
            do {
                try p.run()
                p.waitUntilExit()
            } catch {
                let msg = "[\(Date())] Hata: \(error)\n"
                let logPath = home + "/doa-watcher/logs/app-error.log"
                if let data = msg.data(using: .utf8) {
                    if FileManager.default.fileExists(atPath: logPath) {
                        if let h = FileHandle(forWritingAtPath: logPath) {
                            h.seekToEndOfFile(); h.write(data); h.closeFile()
                        }
                    } else { try? data.write(to: URL(fileURLWithPath: logPath)) }
                }
            }
            NSApp.terminate(nil)
            return
        }
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 760),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window?.title = "DOA Watcher"
        window?.contentView = NSHostingView(rootView: SettingsView())
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let isCheck = CommandLine.arguments.contains("--check")
let app = NSApplication.shared
app.setActivationPolicy(isCheck ? .prohibited : .regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()