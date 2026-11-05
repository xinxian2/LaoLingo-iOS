import SwiftUI
import UIKit

struct AppTheme: Identifiable {
    var id: Int
    var name: String
    var light: UInt32
    var dark: UInt32
    var wash: UInt32
    var night: UInt32
    static let all = [
        AppTheme(id:0,name:"薄荷青柠",light:0x213b16,dark:0xc5ee72,wash:0xe5f8ae,night:0x101b16),
        AppTheme(id:1,name:"海盐蓝",light:0x075c70,dark:0x89dce7,wash:0xc8f5f5,night:0x101d26),
        AppTheme(id:2,name:"蜜桃暖橙",light:0xa64a17,dark:0xffba91,wash:0xffdfc8,night:0x251914),
        AppTheme(id:3,name:"夜间青绿",light:0x0a6667,dark:0xb6f378,wash:0xc9f3e9,night:0x101d20),
        AppTheme(id:4,name:"鼠尾草",light:0x36553d,dark:0xb5d3ad,wash:0xe1efd7,night:0x171f1a),
        AppTheme(id:5,name:"深海暖沙",light:0x284b61,dark:0xb7d5ea,wash:0xffead0,night:0x151d26)
    ]
    func accent(dark mode: Bool) -> Color { Color(hex:mode ? dark : light) }
    func background(dark mode: Bool) -> LinearGradient {
        LinearGradient(colors:mode ? [Color(hex:night),Color(hex:night),Color(hex:light).opacity(0.45)] : [Color(hex:wash).opacity(0.65),Color(uiColor:.systemGroupedBackground),Color(hex:wash).opacity(0.3)],startPoint:.topLeading,endPoint:.bottomTrailing)
    }
}
extension Color {
    init(hex: UInt32) { self.init(red:Double((hex >> 16)&255)/255,green:Double((hex >> 8)&255)/255,blue:Double(hex&255)/255) }
}

// UITextView keeps paragraphs readable while its Return key submits instead of inserting a newline.
// markedTextRange protects Chinese/Lao IME composition from premature submission.
struct TranslationInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    var enabled: Bool
    var accent: Color
    var onSubmit: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle:.body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top:8,left:0,bottom:8,right:0)
        view.returnKeyType = .go
        view.enablesReturnKeyAutomatically = true
        view.keyboardDismissMode = .interactive
        view.accessibilityLabel = appLocalized("翻译输入框")
        let bar = UIToolbar()
        bar.items = [UIBarButtonItem(title:appLocalized("收起键盘"),style:.plain,target:context.coordinator,action:#selector(Coordinator.dismiss)),UIBarButtonItem(systemItem:.flexibleSpace),UIBarButtonItem(title:appLocalized("翻译"),style:.done,target:context.coordinator,action:#selector(Coordinator.submit))]
        bar.sizeToFit(); view.inputAccessoryView = bar
        context.coordinator.view = view
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text && view.markedTextRange == nil { view.text = text }
        if let bar = view.inputAccessoryView as? UIToolbar {
            bar.items?.first?.title = appLocalized("收起键盘")
            bar.items?.last?.title = appLocalized("翻译")
        }
        view.textColor = .label
        view.tintColor = UIColor(accent)
        view.isEditable = enabled
        if focused && !view.isFirstResponder && enabled { view.becomeFirstResponder() }
        if !focused && view.isFirstResponder { view.resignFirstResponder() }
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: TranslationInput
        weak var view: UITextView?
        init(_ parent: TranslationInput) { self.parent = parent }
        func textViewDidBeginEditing(_ textView: UITextView) { parent.focused = true }
        func textViewDidEndEditing(_ textView: UITextView) { parent.focused = false }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text == "\n", textView.markedTextRange == nil { submit(); return false }
            return true
        }
        @objc func dismiss() { view?.resignFirstResponder(); parent.focused = false }
        @objc func submit() {
            guard parent.enabled, view?.markedTextRange == nil else { return }
            parent.text = view?.text ?? parent.text
            dismiss(); parent.onSubmit()
        }
    }
}

struct ProfileView: View {
    @EnvironmentObject var model: Model
    @Binding var login: Bool
    @AppStorage("accountName") private var accountName = ""
    @AppStorage("theme") private var themeID = 0
    @AppStorage("appearance") private var appearance = 0
    @AppStorage("appLanguage") private var language = "system"
    @Environment(\.colorScheme) private var scheme
    var theme: AppTheme { AppTheme.all[min(max(themeID,0),5)] }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:26) {
                    accountCard
                    VStack(alignment:.leading,spacing:16) {
                        Label("主题选择",systemImage:"paintpalette").font(.headline)
                        Text("熟悉的六种配色，适配通透的 iOS 界面").font(.caption).foregroundStyle(.secondary)
                        LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:12) {
                            ForEach(AppTheme.all) { option in
                                Button { withAnimation(.easeInOut(duration:0.25)) { themeID = option.id } } label: {
                                    VStack(alignment:.leading,spacing:14) {
                                        HStack {
                                            Circle().fill(option.accent(dark:scheme == .dark)).frame(width:21,height:21)
                                            Spacer()
                                            if themeID == option.id { Image(systemName:"checkmark.circle.fill").foregroundStyle(option.accent(dark:scheme == .dark)) }
                                        }
                                        RoundedRectangle(cornerRadius:10).fill(.regularMaterial).frame(height:23)
                                        Text(LocalizedStringKey(option.name)).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                    }.padding(15).background(option.background(dark:scheme == .dark),in:RoundedRectangle(cornerRadius:20))
                                        .overlay { RoundedRectangle(cornerRadius:20).stroke(themeID == option.id ? option.accent(dark:scheme == .dark).opacity(0.75) : Color.primary.opacity(0.07),lineWidth:themeID == option.id ? 2 : 1) }
                                }.buttonStyle(.plain).accessibilityAddTraits(themeID == option.id ? .isSelected : [])
                            }
                        }
                    }.padding(20).background(.regularMaterial,in:RoundedRectangle(cornerRadius:26))
                    VStack(spacing:0) {
                        Picker(selection:$appearance) {
                            Text("跟随系统").tag(0); Text("浅色").tag(1); Text("深色").tag(2)
                        } label: { Label("显示模式",systemImage:"circle.lefthalf.filled") }.padding(.vertical,10)
                        Divider()
                        Picker(selection:$language) {
                            Text("跟随系统").tag("system"); Text("简体中文").tag("zh-Hans"); Text("English").tag("en")
                        } label: { Label("系统语言",systemImage:"globe") }.padding(.vertical,10)
                        Divider()
                        NavigationLink { LicensesView() } label: { HStack { Label("开源协议",systemImage:"doc.text"); Spacer(); Image(systemName:"chevron.right").font(.caption).foregroundStyle(.tertiary) } }.foregroundStyle(.primary).padding(.vertical,17)
                    }.padding(.horizontal,20).background(.regularMaterial,in:RoundedRectangle(cornerRadius:26))
                    Text("LaoLingo · 1.1.0").font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity)
                    Text("翻译记录和已播放的音频保存在本机；翻译及首次生成语音需要联网。").font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }.background(theme.background(dark:scheme == .dark).ignoresSafeArea()).navigationTitle("我的")
        }
    }
    var accountCard: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack(spacing:16) {
                Image(systemName:model.token.isEmpty ? "person.crop.circle" : "person.crop.circle.fill")
                    .font(.system(size:50,weight:.light)).foregroundStyle(theme.accent(dark:scheme == .dark))
                VStack(alignment:.leading,spacing:6) {
                    if model.token.isEmpty { Text("未登录").font(.title3.bold()) }
                    else { Text(accountName.isEmpty ? appLocalized("已登录账号") : accountName).font(.title3.bold()) }
                    Text(model.token.isEmpty ? LocalizedStringKey("登录后使用在线翻译") : LocalizedStringKey("已登录 · 凭证安全保存在本机")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack {
                Button(model.token.isEmpty ? LocalizedStringKey("登录") : LocalizedStringKey("切换账号")) { login = true }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                if !model.token.isEmpty { Spacer(); Button("退出登录",role:.destructive) { model.token = ""; Vault.save(""); accountName = "" }.buttonStyle(.borderless) }
            }
        }.padding(23).modifier(Glass())
    }
}

struct LicensesView: View {
    var body: some View {
        List {
            Section("应用说明") {
                Text("iOS 版使用 Apple SwiftUI、UIKit、AVFoundation 和 Security 系统框架，未包含安卓端 Jetpack Compose 等依赖。")
                Text("应用源码的授权以源码仓库中的实际许可证为准；本页面不额外授予未声明的使用权。")
            }
            Section("开源工具与许可") {
                NavigationLink("zsign · MIT License") { LicenseText(title:"zsign · MIT",resource:"zsign-LICENSE") }
                NavigationLink("XcodeGen · MIT License") { LicenseText(title:"XcodeGen · MIT",resource:"XcodeGen-LICENSE") }
                Text("上述工具用于构建或签名，不作为第三方运行库嵌入应用。相关许可证原文随应用提供。")
            }
        }.navigationTitle("开源协议")
    }
}
struct LicenseText: View {
    let title: String
    let resource: String
    var body: some View {
        ScrollView { Text(contents).font(.system(.footnote,design:.monospaced)).textSelection(.enabled).padding(20).frame(maxWidth:.infinity,alignment:.leading) }.navigationTitle(title)
    }
    var contents: String { guard let url = Bundle.main.url(forResource:resource,withExtension:"txt"), let text = try? String(contentsOf:url,encoding:.utf8) else { return "License resource unavailable." }; return text }
}

func appLocalized(_ key: String) -> String {
    let choice = UserDefaults.standard.string(forKey:"appLanguage") ?? "system"
    let identifier = choice == "system" ? (Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh-Hans" : "en") : choice
    let bundle = Bundle.main.path(forResource:identifier,ofType:"lproj").flatMap { Bundle(path:$0) } ?? .main
    return bundle.localizedString(forKey:key,value:key,table:nil)
}
