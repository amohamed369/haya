import SwiftUI

// MARK: - Glass Card

/// Frosted glass card with warm-tinted border and soft shadow.
struct GlassCard: ViewModifier {
    var padding: CGFloat = 24
    var radius: CGFloat = Haya.Radius.lg

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius)
                            .fill(Haya.Colors.glassBgWarm)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(Haya.Colors.glassBorderWarm, lineWidth: 1)
            )
            .shadow(color: Haya.Shadows.soft, radius: 16, y: 8)
    }
}

extension View {
    func glassCard(padding: CGFloat = 24, radius: CGFloat = Haya.Radius.lg) -> some View {
        modifier(GlassCard(padding: padding, radius: radius))
    }
}

// MARK: - Sage Background

/// Full-screen sage green gradient with ambient organic shapes.
struct SageBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    Haya.Gradients.sageBackground
                        .ignoresSafeArea()

                    // Ambient orange glow top-right
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Haya.Colors.accentOrange.opacity(0.08), .clear],
                                center: .center,
                                startRadius: 0,
                                endRadius: 140
                            )
                        )
                        .frame(width: 280, height: 280)
                        .offset(x: 100, y: -120)
                        .ignoresSafeArea()

                    // Ambient lavender glow bottom-left
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Haya.Colors.accentLavender.opacity(0.06), .clear],
                                center: .center,
                                startRadius: 0,
                                endRadius: 100
                            )
                        )
                        .frame(width: 200, height: 200)
                        .offset(x: -80, y: 300)
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

/// Orange pill CTA with glow shadow and scale press effect.
struct HayaPillButtonStyle: ButtonStyle {
    var isProminent: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(HayaFont.pill)
            .tracking(0.3)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(
                Capsule()
                    .fill(isProminent
                        ? AnyShapeStyle(Haya.Gradients.orangeCTA)
                        : AnyShapeStyle(Haya.Colors.glassBg))
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isProminent ? Color.clear : Haya.Colors.glassBorder,
                        lineWidth: 1.5
                    )
            )
            .foregroundStyle(isProminent ? Color(hex: "2A3420") : Haya.Colors.textSage)
            .shadow(
                color: isProminent ? Haya.Shadows.glowOrange : .clear,
                radius: 12, y: 4
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
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
                .tracking(0.2)
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
                            isActive ? Color.clear : Haya.Colors.glassBorder,
                            lineWidth: 1.5
                        )
                )
                .foregroundStyle(isActive ? Color(hex: "2A3420") : Haya.Colors.textSage)
                .shadow(
                    color: isActive ? Haya.Shadows.glowOrange : .clear,
                    radius: 10, y: 2
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Avatar Circle

/// Person avatar with orange gradient and initial letter.
struct AvatarCircle: View {
    let name: String
    var size: CGFloat = 48

    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(HayaFont.heading(size * 0.38, weight: .semibold))
            .foregroundStyle(Color(hex: "3F4F32"))
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(Haya.Gradients.avatarOrange)
            )
            .shadow(color: Haya.Shadows.glowOrange, radius: 8, y: 4)
    }
}

// MARK: - Section Header

/// Fraunces heading with optional "See all" trailing action.
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

// MARK: - Status Badge

/// Small rounded badge for filter status.
struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(HayaFont.caption2)
            .fontWeight(.semibold)
            .tracking(0.3)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(color.opacity(0.15))
            )
            .foregroundStyle(color)
    }
}

// MARK: - Bottom Nav Bar

/// Custom glassmorphism bottom tab bar.
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
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        selectedTab = index
                    }
                } label: {
                    VStack(spacing: 4) {
                        if selectedTab == index {
                            Capsule()
                                .fill(Haya.Colors.accentOrange)
                                .frame(width: 20, height: 3)
                                .shadow(color: Haya.Shadows.glowOrange, radius: 4)
                        } else {
                            Spacer().frame(height: 3)
                        }

                        Image(systemName: tabs[index].icon)
                            .font(.system(size: 20))
                            .foregroundStyle(
                                selectedTab == index
                                    ? Haya.Colors.accentOrange
                                    : Haya.Colors.textSageDim
                            )

                        Text(tabs[index].label)
                            .font(HayaFont.caption2)
                            .foregroundStyle(
                                selectedTab == index
                                    ? Haya.Colors.accentOrange
                                    : Haya.Colors.textSageDim
                            )
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 20)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(
                    Rectangle()
                        .fill(Color(hex: "37442A").opacity(0.85))
                )
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Haya.Colors.glassBorder)
                        .frame(height: 1)
                }
                .ignoresSafeArea(edges: .bottom)
        )
    }
}
