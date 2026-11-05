import SwiftUI
import PhotosUI
import AVFoundation
import Security

struct Entry: Codable, Identifiable {
    var id = UUID()
    var source: String
    var translation: String
    var direction: String
    var mastered = false
    var date = Date()
}
enum Vault {
    static let service = "LaoLingo.session"
    static func read() -> String {
        let q: [String: Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:service, kSecReturnData as String:true]
        var value: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return "" }
        return String(data:data, encoding:.utf8) ?? ""
    }
    static func save(_ token: String) {
        let q: [String: Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service]
        SecItemDelete(q as CFDictionary)
        guard !token.isEmpty else { return }
        var item = q
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary,nil)
    }
}
@MainActor final class Model: ObservableObject {
    @Published var token = Vault.read()
    @Published var entries: [Entry] = []
    @Published var busy = false
    @Published var error = ""
    private var player: AVAudioPlayer?
    private let folder = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
    init() {
        if let data = try? Data(contentsOf:folder.appendingPathComponent("records.json")),
           let saved = try? JSONDecoder().decode([Entry].self,from:data) { entries = saved }
    }
    func persist() {
        do { try JSONEncoder().encode(entries).write(to:folder.appendingPathComponent("records.json"),options:.atomic) }
        catch { self.error = "保存记录失败：" + error.localizedDescription }
    }
    func call(_ path: String, _ body: [String:Any]) async throws -> [String:Any] {
        var request = URLRequest(url:URL(string:"https://fy.atku.cn" + path)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 130
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        if !token.isEmpty { request.setValue("Bearer " + token,forHTTPHeaderField:"Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject:body)
        let (data,response) = try await URLSession.shared.data(for:request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let json = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:]
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 && path != "/login" { token = ""; Vault.save("") }
            throw NSError(domain:"LaoLingo",code:http.statusCode,userInfo:[NSLocalizedDescriptionKey:json["error"] as? String ?? "服务器请求失败"])
        }
        return json
    }
    func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true
        Task { defer { busy = false }; do { try await work() } catch { self.error = error.localizedDescription } }
    }
    func save(source: String, translation: String, direction: String) {
        entries.insert(Entry(source:source,translation:translation,direction:direction),at:0); persist()
    }
    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        // Stable filename without storing private text in the path.
        importAudio(text)
    }
    private func importAudio(_ text: String) {
        run {
            let indexURL = self.folder.appendingPathComponent("audio-index.json")
            var index = ((try? Data(contentsOf:indexURL)).flatMap { try? JSONDecoder().decode([String:String].self,from:$0) }) ?? [:]
            let filename = index[text] ?? UUID().uuidString + ".mp3"
            let url = self.folder.appendingPathComponent(filename)
            if !FileManager.default.fileExists(atPath:url.path) {
                let result = try await self.call("/tts",["text":text])
                guard let encoded = result["audio"] as? String, let bytes = Data(base64Encoded:encoded) else { throw URLError(.cannotDecodeContentData) }
                try bytes.write(to:url,options:.atomic); index[text] = filename
                try JSONEncoder().encode(index).write(to:indexURL,options:.atomic)
            }
            try AVAudioSession.sharedInstance().setCategory(.playback,mode:.default)
            self.player = try AVAudioPlayer(contentsOf:url); self.player?.play()
        }
    }
}
@MainActor final class Recorder: ObservableObject {
    @Published var active = false
    @Published var level: Float = 0
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var heard = false
    private var lastSpeech = Date()
    private var began = Date()
    var onFinish: ((Data) -> Void)?
    func start() async throws {
        let allowed = await withCheckedContinuation { continuation in AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning:$0) } }
        guard allowed else { throw NSError(domain:"mic",code:1,userInfo:[NSLocalizedDescriptionKey:"请在系统设置中允许麦克风访问"]) }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord,mode:.default,options:[.defaultToSpeaker])
        try session.setActive(true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        recorder = try AVAudioRecorder(url:url,settings:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:16000,AVNumberOfChannelsKey:1,AVEncoderAudioQualityKey:AVAudioQuality.medium.rawValue])
        recorder?.isMeteringEnabled = true
        guard recorder?.record() == true else { throw URLError(.cannotCreateFile) }
        heard = false; began = Date(); lastSpeech = Date(); active = true
        timer = Timer.scheduledTimer(withTimeInterval:0.1,repeats:true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
    private func tick() {
        guard let recorder else { return }
        recorder.updateMeters(); level = recorder.averagePower(forChannel:0)
        if level > -38 { heard = true; lastSpeech = Date() }
        if (heard && Date().timeIntervalSince(lastSpeech) >= 1.5) || Date().timeIntervalSince(began) >= 60 { finish(cancel:false) }
    }
    func finish(cancel: Bool) {
        guard active else { return }
        timer?.invalidate(); timer = nil; active = false
        let url = recorder?.url; recorder?.stop(); recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        if let url {
            defer { try? FileManager.default.removeItem(at:url) }
            if !cancel, let data = try? Data(contentsOf:url) { onFinish?(data) }
        }
    }
}
struct Glass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) { content.glassEffect(.regular,in:RoundedRectangle(cornerRadius:24)) }
        else { content.background(.regularMaterial,in:RoundedRectangle(cornerRadius:24)) }
    }
}
@main struct LaoLingoApp: App {
    @StateObject private var model = Model()
    var body: some Scene { WindowGroup { Home().environmentObject(model) } }
}
struct Home: View {
    @EnvironmentObject var model: Model
    @StateObject private var recorder = Recorder()
    @State private var text = ""
    @State private var output = ""
    @State private var reverse = false
    @State private var photo: PhotosPickerItem?
    @State private var login = false
    @State private var user = ""
    @State private var password = ""
    @State private var study: Entry?
    @AppStorage("appearance") private var appearance = 0
    var direction: String { reverse ? "lo-zh" : "zh-lo" }
    var body: some View {
        TabView {
            NavigationStack {
                ScrollView {
                    VStack(alignment:.leading,spacing:22) {
                        Text("让语言，自然流动").font(.title2.bold())
                        Text("中文与老挝语，随时沟通").foregroundStyle(.secondary)
                        HStack {
                            Text(reverse ? "老挝语" : "中文")
                            Spacer()
                            Button { reverse.toggle(); let previous = text; text = output; output = previous } label: { Image(systemName:"arrow.left.arrow.right") }
                            Spacer()
                            Text(reverse ? "中文" : "老挝语")
                        }.font(.headline).padding().modifier(Glass())
                        VStack(alignment:.leading,spacing:16) {
                            TextEditor(text:$text).frame(minHeight:160).scrollContentBackground(.hidden)
                                .overlay(alignment:.topLeading) { if text.isEmpty { Text("输入想翻译的内容…").foregroundStyle(.tertiary).padding(.top,8).allowsHitTesting(false) } }
                            Divider()
                            HStack(spacing:20) {
                                Button { startRecording() } label: { Label(recorder.active ? "录音中" : "语音",systemImage:recorder.active ? "waveform" : "mic") }.disabled(model.busy || recorder.active)
                                if recorder.active {
                                    Button("停止") { recorder.finish(cancel:false) }
                                    Button("取消",role:.cancel) { recorder.finish(cancel:true) }
                                } else {
                                    PhotosPicker(selection:$photo,matching:.images) { Image(systemName:"photo") }.disabled(model.busy)
                                    Spacer()
                                    Button("翻译",systemImage:"arrow.up") { translate() }
                                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).disabled(text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || model.busy)
                                }
                            }
                        }.padding(20).background(.background.opacity(0.8),in:RoundedRectangle(cornerRadius:28))
                        if !output.isEmpty {
                            VStack(alignment:.leading,spacing:20) {
                                Text("译文").font(.caption).foregroundStyle(.secondary)
                                Text(output).font(.title3).textSelection(.enabled)
                                HStack(spacing:24) {
                                    Button { model.speak(output) } label: { Image(systemName:"speaker.wave.2") }
                                    ShareLink(item:output) { Image(systemName:"square.and.arrow.up") }
                                    Button("逐句学习",systemImage:"book") { study = Entry(source:text,translation:output,direction:direction) }
                                }.disabled(model.busy)
                            }.frame(maxWidth:.infinity,alignment:.leading).padding(24).background(.background.opacity(0.8),in:RoundedRectangle(cornerRadius:28))
                        }
                        if model.busy { ProgressView("正在处理…").frame(maxWidth:.infinity) }
                        if recorder.active { Text("说完后静音 1.5 秒自动结束，也可点停止").font(.caption).foregroundStyle(.secondary) }
                    }.padding(22)
                }
                .background(background)
                .navigationTitle("LaoLingo")
                .toolbar { ToolbarItem(placement:.topBarTrailing) { Button { login = true } label: { Image(systemName:model.token.isEmpty ? "person.crop.circle" : "person.crop.circle.fill") } } }
            }.tabItem { Label("翻译",systemImage:"character.bubble") }
            NavigationStack {
                List {
                    if model.entries.isEmpty { ContentUnavailableView("还没有记录",systemImage:"clock",description:Text("翻译完成后会自动保存在本机")) }
                    ForEach(model.entries) { entry in
                        Button { study = entry } label: {
                            VStack(alignment:.leading,spacing:8) {
                                HStack { Text(entry.source).lineLimit(2); if entry.mastered { Image(systemName:"checkmark.seal.fill").foregroundStyle(.green) } }
                                Text(entry.translation).foregroundStyle(.secondary).lineLimit(3)
                            }.padding(.vertical,8)
                        }.foregroundStyle(.primary)
                        .swipeActions(edge:.trailing,allowsFullSwipe:false) {
                            Button("删除",role:.destructive) { model.entries.removeAll { $0.id == entry.id }; model.persist() }
                            Button(entry.mastered ? "标为未掌握" : "标为已掌握") {
                                if let i = model.entries.firstIndex(where:{$0.id == entry.id}) { model.entries[i].mastered.toggle(); model.persist() }
                            }.tint(.teal)
                        }
                    }
                }.navigationTitle("学习记录")
            }.tabItem { Label("学习",systemImage:"book.closed") }
            NavigationStack {
                Form {
                    Section("外观") { Picker("显示模式",selection:$appearance) { Text("跟随系统").tag(0); Text("浅色").tag(1); Text("深色").tag(2) } }
                    Section("账号") { Button(model.token.isEmpty ? "登录" : "切换账号") { login = true }; if !model.token.isEmpty { Button("退出登录",role:.destructive) { model.token = ""; Vault.save("") } } }
                    Section("关于") { LabeledContent("版本",value:"iOS 1.0.0"); Text("翻译记录和已播放的音频保存在本机；翻译及首次生成语音需要联网。").font(.footnote).foregroundStyle(.secondary) }
                }.navigationTitle("设置")
            }.tabItem { Label("设置",systemImage:"slider.horizontal.3") }
        }
        .tint(.teal)
        .preferredColorScheme(appearance == 0 ? nil : appearance == 1 ? .light : .dark)
        .alert("提示",isPresented:Binding(get:{!model.error.isEmpty},set:{if !$0 { model.error = "" }})) { Button("好") { model.error = "" } } message: { Text(model.error) }
        .sheet(isPresented:$login) { NavigationStack { Form {
            TextField("用户名",text:$user).textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("密码",text:$password)
            Button("登录") {
                model.run {
                    let result = try await model.call("/login",["name":user,"password":password])
                    guard let token = result["token"] as? String, !token.isEmpty else { throw URLError(.cannotParseResponse) }
                    model.token = token; Vault.save(token); password = ""; login = false
                }
            }.disabled(user.isEmpty || password.isEmpty || model.busy)
            if model.busy { ProgressView() }
        }.navigationTitle("登录 LaoLingo").toolbar { Button("完成") { login = false } } }.presentationDetents([.medium,.large]) }
        .sheet(item:$study) { StudyView(entry:$0).environmentObject(model) }
        .onChange(of:photo) { _, item in
            guard let item else { return }; guard requireLogin() else { photo = nil; return }
            let d = direction
            model.run {
                defer { photo = nil }
                guard let bytes = try await item.loadTransferable(type:Data.self), let image = UIImage(data:bytes) else { throw URLError(.cannotDecodeContentData) }
                let maxSide: CGFloat = 1600
                let ratio = min(1,maxSide / max(image.size.width,image.size.height))
                let size = CGSize(width:image.size.width * ratio,height:image.size.height * ratio)
                let resized = UIGraphicsImageRenderer(size:size).image { _ in image.draw(in:CGRect(origin:.zero,size:size)) }
                guard let data = resized.jpegData(compressionQuality:0.8) else { throw URLError(.cannotDecodeContentData) }
                let result = try await model.call("/image",["image":"data:image/jpeg;base64," + data.base64EncodedString(),"direction":d])
                text = result["source_text"] as? String ?? ""; output = result["translation"] as? String ?? ""
                if !output.isEmpty { model.save(source:text,translation:output,direction:d) }
            }
        }
        .onDisappear { recorder.finish(cancel:true) }
    }
    var background: some View {
        LinearGradient(colors:[Color.teal.opacity(0.15),Color.blue.opacity(0.06),Color.orange.opacity(0.09)],startPoint:.topLeading,endPoint:.bottomTrailing).ignoresSafeArea()
    }
    func requireLogin() -> Bool { if model.token.isEmpty { login = true; return false }; return true }
    func translate() {
        guard requireLogin() else { return }
        let source = text; let d = direction
        model.run {
            let result = try await model.call("/translate",["text":source,"direction":d,"mode":"daily"])
            guard let translated = result["translation"] as? String, !translated.isEmpty else { throw URLError(.cannotParseResponse) }
            output = translated; model.save(source:source,translation:translated,direction:d)
        }
    }
    func startRecording() {
        guard requireLogin() else { return }
        let language = reverse ? "lo" : "zh"
        recorder.onFinish = { data in model.run {
            let result = try await model.call("/stt",["audio":data.base64EncodedString(),"format":"m4a","language":language])
            text = result["text"] as? String ?? ""
        } }
        Task { do { try await recorder.start() } catch { model.error = error.localizedDescription } }
    }
}
struct StudyPair: Codable, Identifiable {
    var id: String { lao + chinese }
    var lao: String
    var chinese: String
    var words: [StudyWord]
    var note: String
}
struct StudyWord: Codable { var lao: String; var chinese: String }
struct StudyResult: Codable { var pairs: [StudyPair] }
struct StudyView: View {
    let entry: Entry
    @EnvironmentObject var model: Model
    @Environment(\.dismiss) private var dismiss
    @State private var pairs: [StudyPair] = []
    @State private var loading = false
    var cache: URL { FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent(entry.id.uuidString + ".study.json") }
    var body: some View {
        NavigationStack {
            List {
                Section("原文") { Text(entry.source).textSelection(.enabled) }
                Section("译文") { Text(entry.translation).textSelection(.enabled); Button("朗读译文",systemImage:"speaker.wave.2") { model.speak(entry.translation) }.disabled(model.busy) }
                ForEach(pairs) { pair in Section {
                    Button { model.speak(pair.lao) } label: { Label(pair.lao,systemImage:"speaker.wave.2") }.disabled(model.busy)
                    Text(pair.chinese)
                    ForEach(pair.words.indices,id:\.self) { i in Button { model.speak(pair.words[i].lao) } label: { Text(pair.words[i].lao + " · " + pair.words[i].chinese) }.disabled(model.busy) }
                    if !pair.note.isEmpty { Text(pair.note).font(.footnote).foregroundStyle(.secondary) }
                } }
                if pairs.isEmpty {
                    Button("生成逐句学习") {
                        model.run {
                            let result = try await model.call("/study",["source":entry.source,"translation":entry.translation,"direction":entry.direction])
                            let data = try JSONSerialization.data(withJSONObject:result)
                            pairs = try JSONDecoder().decode(StudyResult.self,from:data).pairs
                            try data.write(to:cache,options:.atomic)
                        }
                    }.disabled(model.busy)
                }
                if model.busy { ProgressView() }
            }.navigationTitle("逐句学习").toolbar { Button("完成") { dismiss() } }
                .onAppear { if let data = try? Data(contentsOf:cache), let result = try? JSONDecoder().decode(StudyResult.self,from:data) { pairs = result.pairs } }
        }
    }
}

