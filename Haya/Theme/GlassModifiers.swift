import SwiftUI

// MARK: - Glass Card

/// Frosted glass card with directional gradient border and offset shadow.
struct GlassCard: ViewModifier {
    var padding: CGFloat = 24
    var radius: CGFloat = Haya.Radius.lg

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: radius)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: radius)
                        .fill(Haya.Colors.glassBgWarm)
                    // Inner highlight — simulates light on the top-left edge
                    RoundedRectangle(cornerRadius: radius)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.04),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .center
                            )
                        )
                }
            )
            // Directional gradient border (light source top-left)
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.18),
                                Color.white.opacity(0.06),
                                Color.white.opacity(0.03)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .hayaShadowMd()
    }
}

extension View {
    func glassCard(padding: CGFloat = 24, radius: CGFloat = Haya.Radius.lg) -> some View {
        modifier(GlassCard(padding: padding, radius: radius))
    }

    // MARK: - Shadow Presets

    func hayaShadowSm() -> some View {
        self.compositingGroup()
            .shadow(color: Haya.Shadows.cardDrop, radius: 1, x: 1, y: 2)
            .shadow(color: Haya.Shadows.soft, radius: 4, y: 2)
    }

    func hayaShadowMd() -> some View {
        self.compositingGroup()
            .shadow(color: Haya.Shadows.cardDrop, radius: 1, x: 1.5, y: 2.5)
            .shadow(color: Haya.Shadows.soft, radius: 8, y: 4)
    }

    func hayaShadowLg() -> some View {
        self.compositingGroup()
            .shadow(color: Haya.Shadows.soft, radius: 16, y: 8)
    }
}

// MARK: - Sage Background

/// Full-screen sage gradient with subtle ambient color shifts.
struct SageBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    Haya.Gradients.sageBackground
                        .ignoresSafeArea()

                    // Warm ambient shift top-right
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Haya.Colors.accentOrange.opacity(0.05), .clear],
                                center: .center,
                                startRadius: 0,
                                endRadius: 150
                            )
                        )
                        .frame(width: 300, height: 300)
                        .offset(x: 110, y: -140)
                        .blur(radius: 30)
                        .ignoresSafeArea()

                    // Cool shift bottom-left
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Haya.Colors.accentTeal.opacity(0.03), .clear],
                                center: .center,
                                startRadius: 0,
                                endRadius: 100
                            )
                        )
                        .frame(width: 200, height: 200)
                        .offset(x: -80, y: 300)
                        .blur(radius: 20)
                        .ignoresSafeArea()
                }
            )
    }
}

extension View {
    func sageBackground() -> some View {
        modifier(SageBackground())
    }
}

// MARK: - Pill Button Style

/// Orange pill CTA with offset shadow and translate-down press.
struct HayaPillButtonStyle: ButtonStyle {
    var isProminent: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed

        configuration.label
            .font(HayaFont.pill)
            .tracking(0.4)
            .padding(.horizontal, 28)
            .padding(.vertical, 15)
            .background(
                Capsule()
                    .fill(isProminent
                        ? AnyShapeStyle(Haya.Gradients.orangeCTA)
                        : AnyShapeStyle(Haya.Colors.glassBg))
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isProminent
                            ? AnyShapeStyle(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.22), Color.white.opacity(0.04)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                              )
                            : AnyShapeStyle(Haya.Colors.glassBorder),
                        lineWidth: isProminent ? 1 : 1.5
                    )
            )
            .foregroundStyle(isProminent ? Haya.Colors.fgOnOrange : Haya.Colors.textSage)
            .compositingGroup()
            .shadow(
                color: isProminent
                    ? Haya.Shadows.cardDrop
                    : .clear,
                radius: pressed ? 0 : 1,
                x: pressed ? 0.5 : 2,
                y: pressed ? 0.5 : 3
            )
            // Translate down on press (neobrutalist push)
            .offset(y: pressed ? 2 : 0)
            .animation(Haya.Motion.press, value: pressed)
    }
}

extension ButtonStyle where Self == HayaPillButtonStyle {
    static var hayaPill: HayaPillButtonStyle { .init(isProminent: true) }
    static var hayaPillSecondary: HayaPillButtonStyle { .init(isProminent: false) }
}

// MARK: - Pill Chip

/// Category/tag pill chip (active = orange, inactive = glass).
struct PillChip: View {
    let label: String
    let isActive: Bool
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(HayaFont.pill)
                .tracking(0.3)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(isActive
                            ? AnyShapeStyle(Haya.Colors.accentOrange)
                            : AnyShapeStyle(Haya.Colors.glassBg))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            isActive
                                ? AnyShapeStyle(Color.white.opacity(0.15))
                                : AnyShapeStyle(Haya.Colors.glassBorder),
                            lineWidth: 1
                        )
                )
                .foregroundStyle(isActive ? Haya.Colors.fgOnOrange : Haya.Colors.textSage)
                .compositingGroup()
                .shadow(
                    color: isActive ? Haya.Shadows.cardDrop : .clear,
                    radius: 0.5, x: 1, y: 2
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Avatar Circle

/// Person avatar with orange gradient, border ring, and offset shadow.
struct AvatarCircle: View {
    let name: String
    var size: CGFloat = 48

    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(HayaFont.heading(size * 0.38, weight: .semibold))
            .foregroundStyle(Haya.Colors.fgOnOrangeSoft)
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(Haya.Gradients.avatarOrange)
            )
            .overlay(
                Circle()
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1.5)
            )
            .hayaShadowSm()
    }
}

// MARK: - Section Header

/// Fraunces heading with optional trailing action.
struct SectionHeader: View {
    let title: String
    var trailing: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(HayaFont.title2)
                .foregroundStyle(Haya.Colors.textCream)
            Spacer()
            if let trailing, let action {
                Button(trailing, action: action)
                    .font(HayaFont.caption2)
                    .foregroundStyle(Haya.Colors.accentOrange)
            }
        }
        .padding(.vertical, Haya.Spacing.sm)
    }
}

// MARK: - FilterDecision Display

extension FilterDecision {
    var displayText: String {
        switch self {
        case .keep: return "KEEP"
        case .hide: return "HIDE"
        case .unknown: return "UNKNOWN"
        case .error: return "ERROR"
        }
    }

    var shortText: String {
        switch self {
        case .keep: return "KEEP"
        case .hide: return "HIDE"
        case .unknown: return "?"
        case .error: return "ERR"
        }
    }

    var icon: String {
        switch self {
        case .keep: return "checkmark.circle.fill"
        case .hide: return "eye.slash.fill"
        case .unknown: return "questionmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .keep: return Haya.Colors.accentGreen
        case .hide: return Haya.Colors.statusHide
        case .unknown: return Haya.Colors.accentYellow
        case .error: return Haya.Colors.textSageDim
        }
    }
}

// MARK: - Status Badge

/// Small rounded badge with color-matched border.
struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(HayaFont.caption2)
            .fontWeight(.semibold)
            .tracking(0.4)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(color.opacity(0.12))
            )
            .overlay(
                Capsule().strokeBorder(color.opacity(0.20), lineWidth: 1)
            )
            .foregroundStyle(color)
    }
}

// MARK: - Bottom Nav Bar

/// Custom glassmorphism bottom tab bar with rounded top.
struct HayaTabBar: View {
    @Binding var selectedTab: Int

    private let tabs: [(icon: String, label: String)] = [
        ("photo.on.rectangle.angled", "Photos"),
        ("person.2.fill", "People"),
        ("chart.bar.fill", "Activity"),
        ("gearshape.fill", "Settings")
    ]

    var body: some View {
        HStack {
            ForEach(0..<tabs.count, id: \.self) { index in
                Button {
                    withAnimation(Haya.Motion.quick) {
                        selectedTab = index
                    }
                } label: {
                    VStack(spacing: 5) {
                        // Selected indicator
                        Capsule()
                            .fill(selectedTab == index ? Haya.Colors.accentOrange : Color.clear)
                            .frame(width: selectedTab == index ? 22 : 0, height: 3)

                        Image(systemName: tabs[index].icon)
                            .font(.system(size: 19, weight: selectedTab == index ? .semibold : .regular))
                            .foregroundStyle(
                                selectedTab == index
                                    ? Haya.Colors.accentOrange
                                    : Haya.Colors.textSageDim
                            )

                        Text(tabs[index].label)
                            .font(HayaFont.caption2)
                            .foregroundStyle(
                                selectedTab == index
                                    ? Haya.Colors.textCream
                                    : Haya.Colors.textSageDim
                            )
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 22)
        .background(
            ZStack {
                // Glass base with rounded top
                UnevenRoundedRectangle(
                    topLeadingRadius: 20,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 20
                )
                .fill(.ultraThinMaterial)

                UnevenRoundedRectangle(
                    topLeadingRadius: 20,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 20
                )
                .fill(Haya.Colors.tabBarBg.opacity(0.82))
            }
            .overlay(alignment: .top) {
                // Gradient top border
                UnevenRoundedRectangle(
                    topLeadingRadius: 20,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 20
                )
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.14),
                            Color.white.opacity(0.05),
                            Color.white.opacity(0.02)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            }
            .shadow(color: Haya.Shadows.cardDrop, radius: 8, y: -3)
            .ignoresSafeArea(edges: .bottom)
        )
    }
}
