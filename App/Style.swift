import AppKit
import RelayCore
import SwiftUI

// “航空信”风格：米灰白的纸面、墨蓝色的字、宋体标题；红蓝两色借自航空信封，蓝是 Codex，红是 Claude。
// 红蓝斜条纹只在菜单栏面板顶边和信笺顶边出现，其余地方靠留白和细线分区。

// MARK: - 配色

enum Palette {
    /// 窗口底色
    static let paper = dynamic(0xF8F8F5, 0x18191C)
    /// 信笺、输入框等“纸上的纸”
    static let card = dynamic(0xFFFFFF, 0x202226)
    /// 正文
    static let ink = dynamic(0x1D2331, 0xECEDEF)
    /// 次要文字
    static let ink2 = dynamic(0x666C78, 0x9DA2AC)
    /// 时间、编号等最弱的文字
    static let ink3 = dynamic(0x8C9099, 0x737882)
    /// 细分隔线
    static let line = dynamic(0xE4E3DE, 0x2E3035)
    /// 悬停、选中时的淡底
    static let wash = dynamic(0x1D2331, 0xECEDEF, lightAlpha: 0.05, darkAlpha: 0.07)
    static let codex = dynamic(0x2D55A6, 0x7D9BE6)
    static let claude = dynamic(0xC4473B, 0xEB7C6E)
    static let ok = dynamic(0x2F7A57, 0x5DBB8E)
    static let warn = dynamic(0xA8691A, 0xE0A94F)
    static let bad = dynamic(0xB3261E, 0xF0605A)

    static func platform(_ p: Platform) -> Color { p == .codex ? codex : claude }

    private static func dynamic(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return rgb(isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }

    private static func rgb(_ hex: UInt32, alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

// MARK: - 字体

/// 字号层级：11 / 12 / 13 / 14，标题用系统自带的宋体（19、22、27）
enum Fonts {
    /// 页面标题、信的主题：宋体-简 粗体
    static func display(_ size: CGFloat) -> Font { .custom("STSongti-SC-Bold", size: size) }
    /// “AgentRelay”字样：New York
    static func wordmark(_ size: CGFloat = 17) -> Font { .system(size: size, weight: .semibold, design: .serif) }
    /// 信箱名、编号这类要照着写的地址
    static func mono(_ size: CGFloat = 13, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static let section = Font.system(size: 13, weight: .semibold)
    static let rowTitle = Font.system(size: 14, weight: .medium)
    static let body = Font.system(size: 13)
    static let small = Font.system(size: 12)
    static let tiny = Font.system(size: 11)
}

// MARK: - 版面

extension View {
    /// 页面四周的留白；内容最宽 880，靠左
    func pagePadding() -> some View {
        padding(.horizontal, 52)
            .padding(.top, 50)
            .padding(.bottom, 48)
            .frame(maxWidth: 984, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 页面标题：宋体大字，下面一行说明
struct PageHeader<Trailing: View>: View {
    let lines: [String]
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        lines = [title]
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    init(lines: [String], subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.lines = lines
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(lines, id: \.self) { Text($0) }
                }
                .font(Fonts.display(27))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(Fonts.body)
                        .foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) { trailing }.padding(.top, 4)
        }
    }
}

/// 小节标题：粗一点的 13 号字，右边可以放操作
struct SectionHeader<Trailing: View>: View {
    let title: String
    var note: String?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, note: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.note = note
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(Fonts.section).foregroundStyle(Palette.ink)
            if let note { Text(note).font(Fonts.small).monospacedDigit().foregroundStyle(Palette.ink3) }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.bottom, 8)
    }
}

/// 一像素细线
struct Hairline: View {
    var vertical = false

    var body: some View {
        Rectangle()
            .fill(Palette.line)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// 空状态：说明发生了什么、下一步做什么
struct EmptyState<Action: View>: View {
    let symbol: String
    let title: String
    var message: String?
    var tint: Color = Palette.ink3
    @ViewBuilder var action: Action

    init(_ title: String, symbol: String, message: String? = nil, tint: Color = Palette.ink3,
         @ViewBuilder action: () -> Action = { EmptyView() }) {
        self.title = title
        self.symbol = symbol
        self.message = message
        self.tint = tint
        self.action = action()
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(tint)
            Text(title).font(Fonts.display(19)).foregroundStyle(Palette.ink)
            if let message {
                Text(message)
                    .font(Fonts.small)
                    .foregroundStyle(Palette.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true)
            }
            action.padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 列表里的一行说明文字（比如“还没有信。”）
struct QuietLine: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Fonts.small)
            .foregroundStyle(Palette.ink3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
    }
}

// MARK: - 航空信条纹

/// 红蓝相间的斜条纹，取自航空信封的边
struct AirmailStripe: View {
    var height: CGFloat = 4

    var body: some View {
        Canvas { ctx, size in
            let width: CGFloat = 14, gap: CGFloat = 6, slant = size.height * 1.6
            var x = -slant
            var i = 0
            while x < size.width + slant {
                var p = Path()
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x + slant, y: 0))
                p.addLine(to: CGPoint(x: x + slant + width, y: 0))
                p.addLine(to: CGPoint(x: x + width, y: size.height))
                p.closeSubpath()
                ctx.fill(p, with: .color(i.isMultiple(of: 2) ? Palette.claude : Palette.codex))
                x += width + gap
                i += 1
            }
        }
        .frame(height: height)
        .clipped()
        .accessibilityHidden(true)
    }
}

// MARK: - 平台、信箱、来回链

struct PlatformDot: View {
    let platform: Platform
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(Palette.platform(platform))
            .frame(width: size, height: size)
            .help(platform.displayName)
            .accessibilityLabel(platform.displayName)
    }
}

/// 平台：彩色圆点加名字
struct PlatformBadge: View {
    let platform: Platform

    var body: some View {
        HStack(spacing: 6) {
            PlatformDot(platform: platform, size: 6)
            Text(platform.displayName).font(Fonts.small).foregroundStyle(Palette.ink2)
        }
    }
}

/// 信箱名：等宽字，前面是平台色圆点
struct MailboxLabel: View {
    let name: String
    let platform: Platform
    var size: CGFloat = 13

    var body: some View {
        HStack(spacing: 6) {
            PlatformDot(platform: platform, size: 6)
            Text(name).font(Fonts.mono(size)).foregroundStyle(Palette.ink).lineLimit(1)
        }
    }
}

/// 发信 → 收信
struct RouteLabel: View {
    let message: MessageRow
    var size: CGFloat = 13

    var body: some View {
        HStack(spacing: 7) {
            MailboxLabel(name: message.fromMailbox, platform: message.fromPlatform, size: size)
            Image(systemName: "arrow.right")
                .font(.system(size: size - 3, weight: .medium))
                .foregroundStyle(Palette.ink3)
            MailboxLabel(name: message.toMailbox, platform: message.toPlatform, size: size)
        }
    }
}

/// 来回链已经往返几次：每次一格，格数等于上限（上限超过 12 时改成一根进度条）
struct HopMeter: View {
    let hop: Int
    let limit: Int

    var body: some View {
        Group {
            if limit <= 12 {
                HStack(spacing: 2) {
                    ForEach(1...max(limit, 1), id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(i <= hop ? Palette.ink : Palette.line)
                            .frame(width: 3, height: 10)
                    }
                }
            } else {
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.line)
                    Capsule().fill(Palette.ink).frame(width: 40 * min(1, CGFloat(hop) / CGFloat(limit)))
                }
                .frame(width: 40, height: 3)
            }
        }
        .help("这条来回链已往返 \(hop) 次，最多 \(limit) 次")
        .accessibilityElement()
        .accessibilityLabel("第 \(hop) 次，最多 \(limit) 次")
    }
}

/// 信的状态文字：失败用红色，重试和可能卡住用琥珀色
struct MessageStatusLabel: View {
    let message: MessageRow
    var font: Font = Fonts.small

    var body: some View {
        HStack(spacing: 8) {
            if message.staleFlagged && message.status != .failed {
                Text("可能卡住").foregroundStyle(Palette.warn)
            }
            Text(Format.status(message.status))
                .fontWeight(message.status == .failed ? .medium : .regular)
                .foregroundStyle(color)
        }
        .font(font)
    }

    private var color: Color {
        switch message.status {
        case .failed: return Palette.bad
        case .retrying, .unknown: return Palette.warn
        default: return Palette.ink2
        }
    }
}

/// Claude 会话是否挂着等信程序
struct WaitingLabel: View {
    let waiting: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .strokeBorder(waiting ? Palette.ok : Palette.warn, lineWidth: 1.5)
                .frame(width: 7, height: 7)
            Text(waiting ? "正在等信" : "没在等信")
                .font(Fonts.small)
                .foregroundStyle(waiting ? Palette.ok : Palette.warn)
        }
        .help(waiting ? "有信会立刻叫醒这个会话" : "这个会话现在收不到提醒，需要到会话里说一声“收信”")
    }
}

// MARK: - 按钮

/// 按钮的三种样子：实心墨色（主要操作）、细边框（次要操作）、纯文字（不打扰的操作）
struct InkButtonStyle: ButtonStyle {
    enum Kind { case filled, outline, text, danger }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        InkButtonBody(kind: kind, configuration: configuration)
    }
}

private struct InkButtonBody: View {
    let kind: InkButtonStyle.Kind
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .text || kind == .danger ? 2 : 12)
            .padding(.vertical, kind == .text || kind == .danger ? 2 : 5)
            .background {
                switch kind {
                case .filled: Capsule().fill(Palette.ink)
                case .outline: Capsule().fill(hovering ? Palette.wash : Color.clear)
                case .text, .danger: EmptyView()
                }
            }
            .overlay {
                if kind == .outline { Capsule().strokeBorder(Palette.line, lineWidth: 1) }
            }
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
            .onHover { hovering = $0 }
    }

    private var foreground: Color {
        switch kind {
        case .filled: return Palette.paper
        case .outline: return Palette.ink
        case .text: return hovering ? Palette.ink : Palette.ink2
        case .danger: return Palette.bad
        }
    }
}

extension ButtonStyle where Self == InkButtonStyle {
    static var inkFilled: InkButtonStyle { InkButtonStyle(kind: .filled) }
    static var inkOutline: InkButtonStyle { InkButtonStyle(kind: .outline) }
    static var inkText: InkButtonStyle { InkButtonStyle(kind: .text) }
    static var inkDanger: InkButtonStyle { InkButtonStyle(kind: .danger) }
}

/// 整行可点、悬停时铺一层淡底
struct RowButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        RowButtonBody(configuration: configuration, selected: selected)
    }
}

private struct RowButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        configuration.label
            .contentShape(Rectangle())
            .background(selected || hovering || configuration.isPressed ? Palette.wash : Color.clear)
            .onHover { hovering = $0 }
    }
}

// MARK: - 选择和输入

/// 下拉选择：文字加小箭头，选中的一项打勾
struct MenuPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    var body: some View {
        Menu {
            ForEach(options, id: \.value) { option in
                Toggle(option.label, isOn: Binding(get: { selection == option.value }, set: { _ in selection = option.value }))
            }
        } label: {
            Text(options.first { $0.value == selection }?.label ?? "")
                .font(Fonts.small)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
    }
}

/// 一排文字标签，选中的下面有一条墨线
struct UnderlineTabs<Value: Hashable>: View {
    @Binding var selection: Value
    let items: [(value: Value, label: String, count: Int?)]

    var body: some View {
        HStack(spacing: 26) {
            ForEach(items, id: \.value) { item in
                let on = item.value == selection
                Button { selection = item.value } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(item.label)
                            .font(.system(size: 13, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? Palette.ink : Palette.ink2)
                        if let count = item.count {
                            Text("\(count)").font(Fonts.tiny).monospacedDigit().foregroundStyle(Palette.ink3)
                        }
                    }
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(on ? Palette.ink : Color.clear).frame(height: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// 两三个选项的小胶囊，选中的填墨色
struct PillChoice<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.value) { option in
                let on = option.value == selection
                Button(option.label) { selection = option.value }
                    .buttonStyle(on ? InkButtonStyle(kind: .filled) : InkButtonStyle(kind: .outline))
                    .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// 勾选框：墨色方框，整行可点
struct CheckRow<Label: View>: View {
    @Binding var isOn: Bool
    @ViewBuilder var label: Label

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(isOn ? Palette.ink : Palette.ink3)
                label
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? "已勾选" : "未勾选")
    }
}

extension View {
    /// 输入框：白底、细边、小圆角
    func inkField() -> some View {
        textFieldStyle(.plain)
            .font(Fonts.body)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.line, lineWidth: 1))
    }

    /// 开关：系统开关换成墨色
    func inkSwitch() -> some View {
        toggleStyle(.switch).controlSize(.small).tint(Palette.ink).labelsHidden()
    }
}

/// 数字调节：− 数字 +，数字也可以直接输入
struct ValueStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus", delta: -step).disabled(value <= range.lowerBound)
            TextField("", value: Binding(get: { value }, set: { v in value = min(max(v, range.lowerBound), range.upperBound) }),
                      format: .number)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .frame(width: 64)
            stepButton("plus", delta: step).disabled(value >= range.upperBound)
        }
        .padding(.vertical, 3)
        .background(Palette.card, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1))
    }

    private func stepButton(_ symbol: String, delta: Int) -> some View {
        Button {
            value = min(max(value + delta, range.lowerBound), range.upperBound)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 26, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.inkText)
        .accessibilityLabel(delta < 0 ? "减少" : "增加")
    }
}

// MARK: - 运行状态

/// 运行中 / 已暂停 / 没有启动
struct RunStateLabel: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(Fonts.small).foregroundStyle(Palette.ink2)
        }
    }

    private var text: String {
        if model.runtime.startupError != nil { return "没有启动" }
        return model.paused ? "已暂停" : "运行中"
    }

    private var color: Color {
        if model.runtime.startupError != nil { return Palette.bad }
        return model.paused ? Palette.warn : Palette.ok
    }
}

/// 概览和菜单栏面板顶上的那句话
enum Headline {
    @MainActor
    static func lines(_ model: AppModel) -> [String] {
        if model.runtime.startupError != nil { return ["AgentRelay 没有启动。"] }
        if model.paused { return ["传话已全部暂停，", "恢复前会话发的信都会被退回。"] }
        if model.groups.isEmpty { return ["先登记项目，", "会话才能互相传话。"] }
        if model.needsSetup { return ["项目登记好了，", "还要在“接入”页给两边装上传话工具。"] }
        let first = model.todayCount == 0 ? "今天还没有传信，" : "今天传了 \(model.todayCount) 封信，"
        let second = model.attention.isEmpty ? "一切正常。" : "有 \(model.attention.count) 件事等你处理。"
        return [first, second]
    }

    /// 待处理一项的提示色：送不到、被拦截用红色，交接用墨色，其余琥珀色
    static func color(_ item: AttentionItem) -> Color {
        switch item.kind {
        case .handoff: return Palette.ink
        case .event:
            return ["投递失败", "拦截", "拒绝"].contains(item.title) ? Palette.bad : Palette.warn
        }
    }
}
