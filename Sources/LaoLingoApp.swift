import SwiftUI
import AVFoundation
import Security
import UIKit

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
    @Published var notice = ""
    private var noticeTask: Task<Void,Never>?
    private var player: AVAudioPlayer?
    @Published var playing = false
    @Published var loadingAudio = false
    private var playbackGeneration = 0
    private var playbackTimer: Timer?
    func stopSpeech() { playbackGeneration += 1; player?.stop(); playing = false; loadingAudio = false; playbackTimer?.invalidate() }
    private let folder = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
    init() {
        if let data = try? Data(contentsOf:folder.appendingPathComponent("records.json")),
           let saved = try? JSONDecoder().decode([Entry].self,from:data) { entries = saved }
    }
    func copy(_ text: String) {
        UIPasteboard.general.string = text
        notice = appLocalized("已复制")
        noticeTask?.cancel()
        noticeTask = Task { try? await Task.sleep(for:.seconds(1.8)); if !Task.isCancelled { notice = "" } }
    }
    func persist() {
        do { try JSONEncoder().encode(entries).write(to:folder.appendingPathComponent("records.json"),options:.atomic) }
        catch { self.error = appLocalized("保存记录失败，请重试") }
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
        Task { defer { busy = false }; do { try await work() } catch { self.error = appError(error) } }
    }
    func save(source: String, translation: String, direction: String) {
        entries.insert(Entry(source:source,translation:translation,direction:direction),at:0); persist()
    }
    func speak(_ text: String, language: String = "auto", rate: Float = 1, loop: Bool = false) {
        guard !text.isEmpty else { return }
        stopSpeech()
        let generation = playbackGeneration
        loadingAudio = true
        Task {
            defer { if generation == playbackGeneration { loadingAudio = false } }
            do {
                let indexURL = folder.appendingPathComponent("audio-index.json")
                let key = "tts-v2:" + language + ":" + text
                var index = ((try? Data(contentsOf:indexURL)).flatMap { try? JSONDecoder().decode([String:String].self,from:$0) }) ?? [:]
                let filename = index[key] ?? UUID().uuidString + ".mp3"
                let url = folder.appendingPathComponent(filename)
                if !FileManager.default.fileExists(atPath:url.path) {
                    let result = try await call("/tts",["text":text,"language":language])
                    guard let encoded = result["audio"] as? String, let bytes = Data(base64Encoded:encoded), bytes.count > 64 else { throw URLError(.cannotDecodeContentData) }
                    _ = try AVAudioPlayer(data:bytes)
                    try bytes.write(to:url,options:.atomic)
                    // Reload to retain cache entries written by concurrent downloads.
                    index = ((try? Data(contentsOf:indexURL)).flatMap { try? JSONDecoder().decode([String:String].self,from:$0) }) ?? [:]
                    index[key] = filename
                    try JSONEncoder().encode(index).write(to:indexURL,options:.atomic)
                }
                guard generation == playbackGeneration else { return }
                try AVAudioSession.sharedInstance().setCategory(.playback,mode:.default)
                player = try AVAudioPlayer(contentsOf:url)
                player?.enableRate = true; player?.rate = rate; player?.numberOfLoops = loop ? -1 : 0
                playing = player?.play() ?? false
                playbackTimer = Timer.scheduledTimer(withTimeInterval:0.1,repeats:true) { _ in
                    Task { @MainActor in
                        guard generation == self.playbackGeneration else { return }
                        self.playing = self.player?.isPlaying ?? false
                        if !self.playing { self.playbackTimer?.invalidate() }
                    }
                }
            } catch { if generation == playbackGeneration { self.error = error.localizedDescription } }
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
    @State private var inputFocused = false
    @State private var login = false
    @State private var user = ""
    @State private var password = ""
    @State private var study: Entry?
    @AppStorage("appearance") private var appearance = 0
    @AppStorage("theme") private var themeID = 0
    @AppStorage("appLanguage") private var appLanguage = "system"
    @Environment(\.colorScheme) private var colorScheme
    var theme: AppTheme { AppTheme.all[min(max(themeID,0),5)] }
    var direction: String { reverse ? "lo-zh" : "zh-lo" }
    var body: some View {
        TabView {
            NavigationStack {
                ScrollView {
                    VStack(alignment:.leading,spacing:22) {
                        Text("让语言，自然流动").font(.title2.bold())
                        Text("中文与老挝语，随时沟通").foregroundStyle(.secondary)
                        HStack {
                            Text(reverse ? LocalizedStringKey("老挝语") : LocalizedStringKey("中文"))
                            Spacer()
                            Button { reverse.toggle(); let previous = text; text = output; output = previous } label: { Image(systemName:"arrow.left.arrow.right") }
                            Spacer()
                            Text(reverse ? LocalizedStringKey("中文") : LocalizedStringKey("老挝语"))
                        }.font(.headline).padding().modifier(Glass())
                        VStack(alignment:.leading,spacing:16) {
                            TranslationInput(text:$text, focused:$inputFocused, enabled:!model.busy && !recorder.active, accent:theme.accent(dark:colorScheme == .dark), onSubmit:translate).frame(height:170)
                                .overlay(alignment:.topLeading) { if text.isEmpty { Text("输入想翻译的内容…").foregroundStyle(.tertiary).padding(.top,8).padding(.leading,5).allowsHitTesting(false) } }
                            Divider()
                            HStack(spacing:20) {
                                Button { startRecording() } label: { Label(recorder.active ? LocalizedStringKey("录音中") : LocalizedStringKey("语音"),systemImage:recorder.active ? "waveform" : "mic") }.disabled(model.busy || recorder.active)
                                if recorder.active {
                                    Button("停止") { recorder.finish(cancel:false) }
                                    Button("取消",role:.cancel) { recorder.finish(cancel:true) }
                                } else {
                                    Label("图片翻译暂未开放",systemImage:"lock.fill").font(.caption).foregroundStyle(.secondary).accessibilityLabel(Text("图片翻译已锁定"))
                                    Spacer()
                                    Button("翻译",systemImage:"arrow.up") { translate() }
                                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).disabled(text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || model.busy)
                                }
                            }
                        }.padding(20).background(.background.opacity(0.8),in:RoundedRectangle(cornerRadius:28))
                        if !output.isEmpty {
                            VStack(alignment:.leading,spacing:20) {
                                Text("译文").font(.caption).foregroundStyle(.secondary)
                                Text(output).font(.title3).contextMenu { Button("复制",systemImage:"doc.on.doc") { model.copy(output) } }
                                HStack(spacing:24) {
                                    Button { model.speak(output,language:reverse ? "zh" : "lo") } label: { Image(systemName:"speaker.wave.2") }
                                    Button("复制",systemImage:"doc.on.doc") { model.copy(output) }
                                    ShareLink(item:output) { Image(systemName:"square.and.arrow.up") }
                                    Button("逐句学习",systemImage:"book") { study = Entry(source:text,translation:output,direction:direction) }
                                }.disabled(model.busy)
                            }.frame(maxWidth:.infinity,alignment:.leading).padding(24).background(.background.opacity(0.8),in:RoundedRectangle(cornerRadius:28))
                        }
                        if model.busy { ProgressView("正在处理…").frame(maxWidth:.infinity) }
                        if recorder.active { Text("说完后静音 1.5 秒自动结束，也可点停止").font(.caption).foregroundStyle(.secondary) }
                    }.padding(22)
                }
                .scrollDismissesKeyboard(.interactively)
                .background(background)
                .navigationTitle("LaoLingo")
                .toolbar { ToolbarItem(placement:.topBarTrailing) { Button { login = true } label: { Image(systemName:model.token.isEmpty ? "person.crop.circle" : "person.crop.circle.fill") } } }
            }.tabItem { Label("翻译",systemImage:"character.bubble") }
            NavigationStack {
                List {
                    if model.entries.isEmpty { ContentUnavailableView("还没有记录",systemImage:"clock",description:Text("翻译完成后会自动保存在本机")) }
                    ForEach(model.entries) { entry in
                        VStack(alignment:.leading,spacing:8) {
                            HStack { Text(entry.source).lineLimit(2); if entry.mastered { Image(systemName:"checkmark.seal.fill").foregroundStyle(.green) } }
                            Text(entry.translation).foregroundStyle(.secondary).lineLimit(3)
                        }.frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,8)
                        .contentShape(Rectangle()).onTapGesture { study = entry }
                        .foregroundStyle(.primary)
                        .swipeActions(edge:.trailing,allowsFullSwipe:false) {
                            Button("删除",role:.destructive) { model.entries.removeAll { $0.id == entry.id }; model.persist() }
                            Button(entry.mastered ? LocalizedStringKey("标为未掌握") : LocalizedStringKey("标为已掌握")) {
                                if let i = model.entries.firstIndex(where:{$0.id == entry.id}) { model.entries[i].mastered.toggle(); model.persist() }
                            }.tint(.teal)
                        }
                    }
                }.scrollContentBackground(.hidden).background(background).navigationTitle("学习记录")
            }.tabItem { Label("学习",systemImage:"book.closed") }
            ProfileView(login:$login).environmentObject(model)
                .tabItem { Label("我的",systemImage:"person.crop.circle") }
        }
        .tint(theme.accent(dark:colorScheme == .dark))
        .environment(\.locale,Locale(identifier:resolvedAppLanguage(appLanguage)))
        .preferredColorScheme(appearance == 0 ? nil : appearance == 1 ? .light : .dark)
        .overlay(alignment:.bottom) { if !model.notice.isEmpty { Text(model.notice).font(.subheadline).padding(.horizontal,22).padding(.vertical,12).background(.regularMaterial,in:Capsule()).padding(.bottom,80).allowsHitTesting(false) } }
        .alert("提示",isPresented:Binding(get:{!model.error.isEmpty},set:{if !$0 { model.error = "" }})) { Button("好") { model.error = "" } } message: { Text(model.error) }
        .sheet(isPresented:$login) { NavigationStack { Form {
            TextField("用户名",text:$user).textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("密码",text:$password)
            Button("登录") {
                model.run {
                    let result = try await model.call("/login",["name":user,"password":password])
                    guard let token = result["token"] as? String, !token.isEmpty else { throw URLError(.cannotParseResponse) }
                    model.token = token; Vault.save(token); UserDefaults.standard.set(user,forKey:"accountName"); password = ""; login = false
                }
            }.disabled(user.isEmpty || password.isEmpty || model.busy)
            if model.busy { ProgressView() }
        }.navigationTitle("登录 LaoLingo").toolbar { Button("完成") { login = false } } }.presentationDetents([.medium,.large]) }
        .sheet(item:$study) { StudyView(entry:$0).environmentObject(model) }
        .onDisappear { recorder.finish(cancel:true) }
    }
    var background: some View {
        theme.background(dark:colorScheme == .dark).ignoresSafeArea()
    }
    func requireLogin() -> Bool { if model.token.isEmpty { login = true; return false }; return true }
    func translate() {
        inputFocused = false
        guard !model.busy, !recorder.active, !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
        guard requireLogin() else { return }
        let source = text; let d = direction
        model.run {
            let result = try await model.call("/translate",["text":source,"direction":d,"mode":"daily"])
            guard let translated = result["translation"] as? String, !translated.isEmpty else { throw URLError(.cannotParseResponse) }
            output = translated; model.save(source:source,translation:translated,direction:d)
        }
    }
    func startRecording() {
        inputFocused = false
        guard requireLogin() else { return }
        let language = reverse ? "lo" : "zh"
        recorder.onFinish = { data in model.run {
            let result = try await model.call("/stt",["audio":data.base64EncodedString(),"format":"m4a","language":language])
            text = result["text"] as? String ?? ""
        } }
        Task { do { try await recorder.start() } catch { model.error = appError(error) } }
    }
}
struct StudyPair: Codable, Identifiable {
    var id: String { lao + chinese }
    var lao: String
    var chinese: String
    var words: [StudyWord]
    var note: String
    var structure: String?
    var scenarios: [StudyScenario]?
}
struct StudyScenario: Codable { var title: String; var description: String }
struct StudyWord: Codable { var lao: String; var chinese: String; var ipa: String? }
struct StudyResult: Codable { var pairs: [StudyPair] }
struct StudyView: View {
    let entry: Entry
    @EnvironmentObject var model: Model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var pairs: [StudyPair] = []
    @State private var current = 0
    @State private var slow = false
    @State private var looping = false
    @State private var quiz = false
    @State private var revealed = false
    @State private var bookmarked = false
    var cache: URL { FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent(entry.id.uuidString + ".study.json") }
    var mastered: Bool { model.entries.first(where:{$0.id == entry.id})?.mastered ?? entry.mastered }
    var accent: Color { .blue }
    func play(_ text: String) { model.speak(text,language:"lo",rate:slow ? 0.75 : 1,loop:looping) }
    func generate() {
        model.run {
            let result = try await model.call("/study",["source":entry.source,"translation":entry.translation,"direction":entry.direction])
            let data = try JSONSerialization.data(withJSONObject:result)
            let generated = try JSONDecoder().decode(StudyResult.self,from:data).pairs
            guard !generated.isEmpty else { throw URLError(.cannotDecodeContentData) }
            try data.write(to:cache,options:.atomic)
            model.stopSpeech(); current = 0; pairs = generated; quiz = false
        }
    }
    func card<Content: View>(_ tint: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment:.leading,spacing:14,content:content).padding(18).frame(maxWidth:.infinity,alignment:.leading)
            .background(tint.opacity(scheme == .dark ? 0.19 : 0.09),in:RoundedRectangle(cornerRadius:24))
            .overlay(RoundedRectangle(cornerRadius:24).stroke(tint.opacity(0.15)))
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    if !pairs.isEmpty {
                        let pair = pairs[min(current,pairs.count-1)]
                        HStack { Spacer(); Text("日常表达 · \(current+1) / \(pairs.count)").font(.subheadline).foregroundStyle(.secondary); Spacer() }
                        card(.blue) {
                            Text("逐句理解").font(.caption.weight(.semibold)).foregroundStyle(accent)
                            Text(quiz && !revealed ? "回忆这句话的意思" : pair.chinese).font(.title3.bold())
                            if quiz && !revealed { Button("揭晓译文") { revealed = true } }
                            Text(pair.lao).font(.system(size:29,weight:.semibold)).foregroundStyle(accent).textSelection(.enabled)
                            HStack(spacing:12) {
                                Button { if model.playing || model.loadingAudio { model.stopSpeech() } else { play(pair.lao) } } label: {
                                    Image(systemName:model.playing ? "pause.fill" : "play.fill").font(.title3).frame(width:44,height:44).background(.blue.opacity(0.15),in:Circle())
                                }.accessibilityLabel(model.playing ? "暂停朗读" : "朗读老挝语")
                                if model.loadingAudio { ProgressView() }
                                TimelineView(.animation(minimumInterval:0.12,paused:!model.playing)) { timeline in
                                    HStack(spacing:3) { ForEach(0..<18,id:\.self) { i in Capsule().fill(accent.opacity(0.65)).frame(width:3,height:model.playing ? 7 + abs(sin(timeline.date.timeIntervalSinceReferenceDate*5+Double(i)))*18 : 6) } }.frame(height:30)
                                }.accessibilityHidden(true)
                                Spacer(minLength:0)
                                Button(slow ? "慢速" : "正常") { slow.toggle(); if model.playing { play(pair.lao) } }.font(.caption.bold())
                                Button { looping.toggle(); if model.playing { play(pair.lao) } } label: { Image(systemName:"repeat").foregroundStyle(looping ? accent : .secondary) }.accessibilityLabel(looping ? "关闭循环" : "循环朗读")
                            }
                        }
                        Text("词语拆解 · 点击听发音").font(.headline)
                        ForEach(pair.words.indices,id:\.self) { i in
                            let word = pair.words[i]
                            Button { model.speak(word.lao,language:"lo",rate:slow ? 0.75 : 1) } label: {
                                HStack(spacing:12) {
                                    Capsule().fill(i % 2 == 0 ? Color.orange : Color.green).frame(width:4,height:34)
                                    VStack(alignment:.leading,spacing:3) { Text(word.lao).font(.title3); if let ipa = word.ipa, !ipa.isEmpty { Text("/"+ipa+"/").font(.caption).foregroundStyle(.secondary) } }
                                    Spacer(); Text(quiz && !revealed ? "•••" : word.chinese).foregroundStyle(.secondary); Image(systemName:"speaker.wave.2").foregroundStyle(accent)
                                }.padding(.vertical,5).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Divider()
                        }
                        card(.orange) {
                            Text("句式理解").font(.headline)
                            if !quiz || revealed {
                                if let structure = pair.structure, !structure.isEmpty { Text(structure) }
                                Text(pair.note).font(.subheadline).foregroundStyle(.secondary)
                            } else { Text("先回忆，再揭晓句式和用法").foregroundStyle(.secondary) }
                        }
                        if let scenarios = pair.scenarios, !scenarios.isEmpty, !quiz || revealed {
                            Text("使用场景").font(.headline)
                            ForEach(scenarios.indices,id:\.self) { i in card(i % 2 == 0 ? .blue : .green) { Label(scenarios[i].title,systemImage:"bubble.left.and.bubble.right").font(.headline); Text(scenarios[i].description).font(.subheadline).foregroundStyle(.secondary) } }
                        }
                        card(.blue) {
                            HStack { Image(systemName:"brain.head.profile").foregroundStyle(.orange); VStack(alignment:.leading) { Text("回忆练习").font(.headline); Text("遮住释义，试着说一遍。").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button(quiz ? "结束" : "开始") { quiz.toggle(); revealed = false } }
                        }
                        if pairs.count > 1 { HStack { Button("上一句") { model.stopSpeech(); current -= 1; revealed = false }.disabled(current == 0); Spacer(); Button("下一句") { model.stopSpeech(); current += 1; revealed = false }.disabled(current == pairs.count-1) } }
                        Text("AI 发音标注与解释仅供辅助，请结合语音核对。").font(.caption).foregroundStyle(.secondary)
                        Button("重新生成学习内容和音标",action:generate).disabled(model.busy)
                    } else {
                        card(.blue) { Text(entry.translation).font(.title2); Text("从一句话，理解到一个词。"); Button("生成逐句学习",action:generate).disabled(model.busy); if model.busy { ProgressView() } }
                    }
                }.padding(20)
            }.background(Color(uiColor:scheme == .dark ? .systemBackground : .secondarySystemBackground))
                .navigationTitle("逐句学习").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.topBarLeading) { Button { dismiss() } label: { Image(systemName:"chevron.left") } }
                    ToolbarItem(placement:.topBarTrailing) { Button { bookmarked.toggle(); UserDefaults.standard.set(bookmarked,forKey:"study-bookmark-"+entry.id.uuidString) } label: { Image(systemName:bookmarked ? "bookmark.fill" : "bookmark") }.accessibilityLabel("收藏本条学习记录") }
                }
                .safeAreaInset(edge:.bottom) {
                    HStack(spacing:12) {
                        Button { if !pairs.isEmpty { play(pairs[current].lao) } } label: { Label("再听一遍",systemImage:"arrow.clockwise").frame(maxWidth:.infinity) }.buttonStyle(.bordered)
                        Button {
                            if let i = model.entries.firstIndex(where:{$0.id == entry.id}) { model.entries[i].mastered.toggle(); model.persist() }
                            else { var saved = entry; saved.mastered = true; model.entries.insert(saved,at:0); model.persist() }
                        } label: { Label(mastered ? "标为未掌握" : "标为已掌握",systemImage:"checkmark").frame(maxWidth:.infinity) }.buttonStyle(.borderedProminent)
                    }.padding().background(.ultraThinMaterial).disabled(pairs.isEmpty)
                }
                .onAppear { bookmarked = UserDefaults.standard.bool(forKey:"study-bookmark-"+entry.id.uuidString); if let data = try? Data(contentsOf:cache), let result = try? JSONDecoder().decode(StudyResult.self,from:data) { pairs = result.pairs } }
                .onDisappear { model.stopSpeech() }
        }
    }
}
