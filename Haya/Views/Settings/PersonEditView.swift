import SwiftUI
import PhotosUI
import CoreImage

/// Edit an enrolled person: rename, add/remove photos, change filter mode.
struct PersonEditView: View {
    @EnvironmentObject var pipeline: Pipeline
    @Environment(\.dismiss) private var dismiss

    let enrollment: PersonEnrollment
    var onDismiss: () -> Void

    @State private var name: String = ""
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var newImages: [UIImage] = []
    @State private var filterMode: FilterMode = .defaultFilter
    @State private var customPrompt: String = ""
    @State private var isSaving = false
    @State private var showDeleteConfirm = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Haya.Spacing.md) {
                    // Avatar + Name
                    nameSection
                        .padding(.horizontal, Haya.Spacing.lg)

                    // Current enrollment info
                    enrollmentInfoCard
                        .padding(.horizontal, Haya.Spacing.lg)

                    // Add more photos
                    addPhotosSection
                        .padding(.horizontal, Haya.Spacing.lg)

                    // Filter mode
                    filterModeSection
                        .padding(.horizontal, Haya.Spacing.lg)

                    // Delete
                    deleteSection
                        .padding(.horizontal, Haya.Spacing.lg)

                    Spacer().frame(height: 40)
                }
                .padding(.top, Haya.Spacing.md)
            }
            .sageBackground()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Haya.Colors.textSage)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .foregroundStyle(Haya.Colors.accentOrange)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .onAppear {
            name = enrollment.name
        }
        .alert("Delete Person?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await deletePerson() }
            }
        } message: {
            Text("This will remove \(enrollment.name) and all their enrollment data. This cannot be undone.")
        }
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Name Section

    private var nameSection: some View {
        VStack(spacing: Haya.Spacing.md) {
            AvatarCircle(name: name.isEmpty ? "?" : name, size: 80)

            TextField("Name", text: $name)
                .font(HayaFont.title3)
                .foregroundStyle(Haya.Colors.textCream)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Haya.Spacing.md)
                .padding(.vertical, Haya.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: Haya.Radius.sm)
                        .fill(Haya.Colors.glassBg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Haya.Radius.sm)
                        .strokeBorder(Haya.Colors.glassBorder, lineWidth: 1)
                )
        }
    }

    // MARK: - Enrollment Info

    private var enrollmentInfoCard: some View {
        VStack(alignment: .leading, spacing: Haya.Spacing.md) {
            SectionHeader(title: "Enrollment Data")

            VStack(spacing: Haya.Spacing.sm) {
                infoRow("Face Embeddings", value: "\(enrollment.faceEmbeddingCount)", icon: "face.smiling", color: Haya.Colors.accentGreen)
                infoRow("Body Embeddings", value: "\(enrollment.bodyEmbeddingCount)", icon: "figure.stand", color: Haya.Colors.accentTeal)
            }
        }
        .glassCard()
    }

    private func infoRow(_ label: String, value: String, icon: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 24)
            Text(label)
                .font(HayaFont.bodyText)
                .foregroundStyle(Haya.Colors.textCream)
            Spacer()
            Text(value)
                .font(HayaFont.bodyText)
                .foregroundStyle(Haya.Colors.textSageDim)
        }
    }

    // MARK: - Add Photos

    private var addPhotosSection: some View {
        VStack(alignment: .leading, spacing: Haya.Spacing.md) {
            SectionHeader(title: "Add More Photos")

            Text("Add more photos to improve recognition accuracy.")
                .font(HayaFont.caption)
                .foregroundStyle(Haya.Colors.textSageDim)

            if !newImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Haya.Spacing.sm) {
                        ForEach(newImages.indices, id: \.self) { index in
                            Image(uiImage: newImages[index])
                                .resizable()
                                .scaledToFill()
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: Haya.Radius.sm))
                                .overlay(alignment: .topTrailing) {
                                    Button {
                                        newImages.remove(at: index)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 18))
                                            .foregroundStyle(.white)
                                            .shadow(radius: 2)
                                    }
                                    .offset(x: 6, y: -6)
                                }
                        }
                    }
                }
            }

            PhotosPicker(
                selection: $selectedItems,
                maxSelectionCount: 20,
                matching: .images
            ) {
                HStack {
                    Image(systemName: "photo.badge.plus")
                    Text("Select Photos")
                }
                .font(HayaFont.pill)
                .foregroundStyle(Haya.Colors.accentOrange)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: Haya.Radius.sm)
                        .strokeBorder(Haya.Colors.accentOrange.opacity(0.3), lineWidth: 1.5)
                )
            }
            .onChange(of: selectedItems) { _, items in
                Task { await loadSelectedPhotos(items) }
            }
        }
        .glassCard()
    }

    // MARK: - Filter Mode

    private var filterModeSection: some View {
        VStack(alignment: .leading, spacing: Haya.Spacing.md) {
            SectionHeader(title: "Filter Mode")

            ForEach(FilterMode.allCases, id: \.rawValue) { mode in
                Button {
                    filterMode = mode
                } label: {
                    HStack {
                        Image(systemName: filterMode == mode ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(filterMode == mode ? Haya.Colors.accentOrange : Haya.Colors.textSageDim)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.displayName)
                                .font(HayaFont.bodyText)
                                .foregroundStyle(Haya.Colors.textCream)
                            Text(mode.description)
                                .font(HayaFont.caption)
                                .foregroundStyle(Haya.Colors.textSageDim)
                        }

                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }

            if filterMode == .custom {
                TextEditor(text: $customPrompt)
                    .font(HayaFont.caption)
                    .foregroundStyle(Haya.Colors.textCream)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 80)
                    .padding(Haya.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: Haya.Radius.sm)
                            .fill(Haya.Colors.glassBg)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Haya.Radius.sm)
                            .strokeBorder(Haya.Colors.glassBorder, lineWidth: 1)
                    )
            }
        }
        .glassCard()
    }

    // MARK: - Delete

    private var deleteSection: some View {
        Button {
            showDeleteConfirm = true
        } label: {
            HStack {
                Image(systemName: "trash")
                Text("Delete Person")
            }
            .font(HayaFont.pill)
            .foregroundStyle(Haya.Colors.statusHide)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: Haya.Radius.sm)
                    .strokeBorder(Haya.Colors.statusHide.opacity(0.3), lineWidth: 1.5)
            )
        }
    }

    // MARK: - Actions

    private func loadSelectedPhotos(_ items: [PhotosPickerItem]) async {
        var images: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                images.append(image)
            }
        }
        newImages = images
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        // Re-enroll with new images if provided
        if !newImages.isEmpty {
            let ciImages = newImages.compactMap { uiImage -> CIImage? in
                guard let cgImage = uiImage.cgImage else { return nil }
                return CIImage(cgImage: cgImage)
            }

            do {
                try await pipeline.identifier.removeEnrollment(id: enrollment.id)
                _ = try await pipeline.identifier.enroll(name: name.trimmingCharacters(in: .whitespaces), images: ciImages)
            } catch {
                errorMessage = "Save failed: \(error.localizedDescription)"
                return
            }
        }

        onDismiss()
        dismiss()
    }

    private func deletePerson() async {
        do {
            try await pipeline.identifier.removeEnrollment(id: enrollment.id)
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
            return
        }
        onDismiss()
        dismiss()
    }
}

// MARK: - FilterMode Extensions

extension FilterMode {
    var displayName: String {
        switch self {
        case .defaultFilter: return "Default"
        case .alwaysHide: return "Always Hide"
        case .custom: return "Custom Prompt"
        }
    }

    var description: String {
        switch self {
        case .defaultFilter: return "Use the global filter settings"
        case .alwaysHide: return "Always hide photos of this person"
        case .custom: return "Use a custom VLM prompt for this person"
        }
    }
}
