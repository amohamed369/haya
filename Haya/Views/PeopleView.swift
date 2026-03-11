import SwiftUI
import PhotosUI
import CoreImage

/// People management: list enrolled people, add/edit/delete.
struct PeopleView: View {
    @EnvironmentObject var pipeline: Pipeline

    @State private var enrollments: [PersonEnrollment] = []
    @State private var showNewEnrollment = false
    @State private var editingEnrollment: PersonEnrollment?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Haya.Spacing.xs) {
                    Text("People")
                        .font(HayaFont.largeTitle)
                        .foregroundStyle(Haya.Colors.textCream)
                    Text("\(enrollments.count) enrolled")
                        .font(HayaFont.caption)
                        .foregroundStyle(Haya.Colors.textSageDim)
                }
                Spacer()
            }
            .padding(.horizontal, Haya.Spacing.lg)
            .padding(.top, Haya.Spacing.md)
            .padding(.bottom, Haya.Spacing.md)

            if enrollments.isEmpty {
                Spacer()
                emptyState
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: Haya.Spacing.md) {
                        ForEach(enrollments) { enrollment in
                            personCard(enrollment)
                                .onTapGesture {
                                    editingEnrollment = enrollment
                                }
                        }
                    }
                    .padding(.horizontal, Haya.Spacing.lg)
                    .padding(.bottom, 120) // Tab bar space
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // FAB
            Button {
                showNewEnrollment = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color(hex: "2A3420"))
                    .frame(width: 56, height: 56)
                    .background(
                        Circle().fill(Haya.Gradients.orangeCTA)
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.22), Color.white.opacity(0.04)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: Haya.Shadows.cardDrop, radius: 1, x: 2, y: 3)
                    .shadow(color: Haya.Shadows.soft, radius: 6, y: 3)
            }
            .padding(.trailing, Haya.Spacing.lg)
            .padding(.bottom, 110)
            .disabled(!pipeline.isReady)
        }
        .sheet(isPresented: $showNewEnrollment) {
            AddPersonSheet { _, _ in
                Task { await refreshEnrollments() }
            }
            .environmentObject(pipeline)
        }
        .sheet(item: $editingEnrollment) { enrollment in
            PersonEditView(enrollment: enrollment) {
                Task { await refreshEnrollments() }
            }
            .environmentObject(pipeline)
        }
        .task {
            await refreshEnrollments()
        }
    }

    private var emptyState: some View {
        VStack(spacing: Haya.Spacing.md) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Haya.Colors.textSageDim)

            Text("No People Enrolled")
                .font(HayaFont.title3)
                .foregroundStyle(Haya.Colors.textCream)

            Text("Add people so Haya can recognize them in your photos.")
                .font(HayaFont.bodyText)
                .foregroundStyle(Haya.Colors.textSage)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Haya.Spacing.xxl)
        }
    }

    private func personCard(_ enrollment: PersonEnrollment) -> some View {
        HStack(spacing: Haya.Spacing.md) {
            AvatarCircle(name: enrollment.name, size: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text(enrollment.name)
                    .font(HayaFont.headline)
                    .foregroundStyle(Haya.Colors.textCream)

                HStack(spacing: Haya.Spacing.sm) {
                    if enrollment.faceCentroid != nil {
                        Label("\(enrollment.faceEmbeddingCount)", systemImage: "face.smiling")
                            .font(HayaFont.caption)
                            .foregroundStyle(Haya.Colors.accentGreen)
                    }
                    if enrollment.bodyCentroid != nil {
                        Label("\(enrollment.bodyEmbeddingCount)", systemImage: "figure.stand")
                            .font(HayaFont.caption)
                            .foregroundStyle(Haya.Colors.accentTeal)
                    }
                }
            }

            Spacer()

            // Filter mode badge
            StatusBadge(
                text: "Default",
                color: Haya.Colors.accentOrange
            )

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Haya.Colors.textSageDim)
        }
        .glassCard(padding: 16, radius: Haya.Radius.lg)
        .contextMenu {
            Button(role: .destructive) {
                Task {
                    try? await pipeline.identifier.removeEnrollment(id: enrollment.id)
                    await refreshEnrollments()
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func refreshEnrollments() async {
        enrollments = await pipeline.identifier.currentEnrollments
    }
}
