import AVFoundation
import SwiftUI
import UIKit

struct PreviewPanel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(.primary.opacity(0.08))
                    .allowsHitTesting(false)
            }
    }
}

struct PreviewBrand: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "character.bubble.fill")
                .font(.system(size: 35, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 80, height: 80)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 25))
                .accessibilityHidden(true)
            Text("LaoLingo").font(.title2.weight(.semibold))
        }
    }
}

struct PreviewWelcome: View {
    @AppStorage("theme") private var themeID = 1
    @AppStorage("appearance") private var appearance = 0
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0
    @State private var requesting = false
    @State private var appeared = false
    let onFinish: () -> Void

    private var theme: AppTheme { AppTheme.all[min(max(themeID, 0), 5)] }
    private var isDark: Bool { scheme == .dark }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                HStack {
                    if step > 0 {
                        Button { advance(to: step - 1) } label: {
                            Image(systemName: "chevron.left")
                                .frame(width: 44, height: 44)
                                .background(.regularMaterial, in: Circle())
                        }.accessibilityLabel(Text("返回"))
                    }
                    Spacer()
                    Text(verbatim: "\(step + 1) / 3").monospacedDigit().foregroundStyle(.secondary)
                }
                Group {
                    switch step {
                    case 1: appearanceStep
                    case 2: microphoneStep
                    default: welcomeStep
                    }
                }.id(step).transition(.opacity)
                actions
            }.frame(maxWidth: 460).padding(24).frame(maxWidth: .infinity)
        }
        .background(theme.background(dark: isDark).ignoresSafeArea())
        .tint(theme.accent(dark: isDark))
        .preferredColorScheme(appearance == 0 ? nil : appearance == 1 ? .light : .dark)
        .interactiveDismissDisabled()
        .task {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.42)) { appeared = true }
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 12) {
            PreviewBrand().opacity(appeared ? 1 : 0).scaleEffect(appeared || reduceMotion ? 1 : 0.96)
            Text("中文与老挝语互译").font(.title3.weight(.semibold))
            Text("文字翻译、语音输入和逐句学习").font(.subheadline).foregroundStyle(.secondary)
        }.padding(.vertical, 48)
    }

    private var appearanceStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("选择外观", systemImage: "paintpalette").font(.title2.weight(.semibold))
            Picker("显示模式", selection: $appearance) {
                Text("跟随系统").tag(0)
                Text("浅色").tag(1)
                Text("深色").tag(2)
            }.pickerStyle(.segmented)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                ForEach(AppTheme.all) { option in
                    Button { themeID = option.id } label: {
                        VStack(spacing: 6) {
                            Circle().fill(option.accent(dark: isDark)).frame(width: 25, height: 25)
                                .overlay {
                                    if themeID == option.id {
                                        Image(systemName: "checkmark").font(.caption.bold())
                                            .foregroundStyle(isDark ? Color.black : Color.white)
                                    }
                                }
                            Text(LocalizedStringKey(option.name)).font(.caption)
                        }.frame(maxWidth: .infinity, minHeight: 64)
                    }.buttonStyle(.plain).accessibilityAddTraits(themeID == option.id ? .isSelected : [])
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("你好").font(.headline)
                Text(verbatim: "ສະບາຍດີ").font(.title3).foregroundStyle(.tint)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(14).modifier(PreviewPanel())
        }.padding(.vertical, 20)
    }

    private var microphoneStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.circle.fill").font(.system(size: 56)).foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("语音输入").font(.title2.weight(.semibold))
            Text("点击麦克风后才开始录音。你也可以先用文字翻译。")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }.padding(.vertical, 42)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                if step < 2 { advance(to: step + 1) }
                else {
                    requesting = true
                    Task { @MainActor in
                        _ = await AVAudioApplication.requestRecordPermission()
                        requesting = false
                        onFinish()
                    }
                }
            } label: {
                Text(step == 0 ? LocalizedStringKey("开始使用") : step == 1 ? LocalizedStringKey("继续") : LocalizedStringKey("开启语音"))
                    .frame(maxWidth: .infinity, minHeight: 34)
            }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).disabled(requesting)
            if step == 2 { Button("稍后设置", action: onFinish).disabled(requesting) }
        }
    }

    private func advance(to value: Int) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { step = value }
    }
}
