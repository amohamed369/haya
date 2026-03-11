import SwiftUI
import PhotosUI
import CoreImage
import Vision

/// Onboarding step: enroll one or more people with name + photos.
struct PersonSetupView: View {
    @EnvironmentObject var pipeline: Pipeline
    var onComplete: () -> Void

    @State private var enrolledPeople: [EnrolledPreview] = []
    @State private var showAddSheet = false
    @State private var animateIn = false

    struct EnrolledPreview: Identifiable {
        let id = UUID()
        let name: String
        let photoCount: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: Haya.Spacing.sm) {
                Text("Who do you want to protect?")
                    .font(HayaFont.title)
                    .foregroundStyle(Haya.Colors.textCream)
                    .multilineTextAlignment(.center)

                Text("Select photos of each person so Haya can recognize them. At least 3 photos per person.")
                    .font(HayaFont.bodyText)
                    .foregroundStyle(Haya.Colors.textSage)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, Haya.Spacing.lg)
            .padding(.top, Haya.Spacing.xl)
            .opacity(animateIn ? 1 : 0)
            .offset(y: animateIn ? 0 : 20)

            Spacer().frame(height: Haya.Spacing.xl)

            // Enrolled people list
            ScrollView {
                LazyVStack(spacing: Haya.Spacing.md) {
                    ForEach(enrolledPeople) { person in
                        enrolledPersonCard(person)
                    }

                    // Add person button
                    Button {
                        showAddSheet = true
                    } label: {
                        HStack(spacing: Haya.Spacing.md) {
                            ZStack {
                                Circle()
                                    .strokeBorder(Haya.Colors.glassBorder, lineWidth: 2)
                                    .frame(width: 48, height: 48)
                                Image(systemName: "plus")
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundStyle(Haya.Colors.accentOrange)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Add a person")
                                    .font(HayaFont.headline)
                                    .foregroundStyle(Haya.Colors.textCream)
                                Text("Select 3+ photos to enroll")
                                    .font(HayaFont.caption)
                                    .foregroundStyle(Haya.Colors.textSageDim)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Haya.Colors.textSageDim)
                        }
                        .glassCard(padding: 16, radius: Haya.Radius.lg)
                    }
                    .buttonStyle(.plain)
                    .disabled(!pipeline.isEnrollReady)
                }
                .padding(.horizontal, Haya.Spacing.lg)
            }

            Spacer()

            // Continue button
            if !enrolledPeople.isEmpty {
                Button("Start Scanning") {
                    onComplete()
                }
                .buttonStyle(.hayaPill)
                .padding(.bottom, Haya.Spacing.xl)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                Button("Skip for Now") {
                    onComplete()
                }
                .buttonStyle(.hayaPillSecondary)
                .padding(.bottom, Haya.Spacing.xl)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddPersonSheet { name, count in
                enrolledPeople.append(EnrolledPreview(name: name, photoCount: count))
            }
            .environmentObject(pipeline)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6).delay(0.1)) {
                animateIn = true
            }
        }
    }

    private func enrolledPersonCard(_ person: EnrolledPreview) -> some View {
        HStack(spacing: Haya.Spacing.md) {
            AvatarCircle(name: person.name, size: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                    .font(HayaFont.headline)
                    .foregroundStyle(Haya.Colors.textCream)
                Text("\(person.photoCount) photos enrolled")
                    .font(HayaFont.caption)
                    .foregroundStyle(Haya.Colors.textSageDim)
            }

            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(Haya.Colors.accentGreen)
        }
        .glassCard(padding: 16, radius: Haya.Radius.lg)
    }
}

// MARK: - Add Person Sheet

struct AddPersonSheet: View {
    @EnvironmentObject var pipeline: Pipeline
    @Environment(\.dismiss) var dismiss
    var onEnrolled: (String, Int) -> Void

    @State private var name = ""
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var selectedImages: [UIImage] = []
    @State private var isProcessing = false
    @State private var errorMessage: String?

    // Face disambiguation
    @State private var faceCounts: [Int] = []           // face count per photo
    @State private var faceSelections: [CGRect?] = []   // selected face rect per photo (nil = auto)
    @State private var pendingFacePicks: [Int] = []     // indices of photos needing face selection
    @State private var currentFacePickIndex: Int?       // which photo is showing face picker
    @State private var isDetectingFaces = false

    var body: some View {
        NavigationStack {
            ZStack {
                Haya.Gradients.sageBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: Haya.Spacing.lg) {
                        // Name input
                        VStack(alignment: .leading, spacing: Haya.Spacing.sm) {
                            Text("Name")
                                .font(HayaFont.label)
                                .foregroundStyle(Haya.Colors.textSage)
                                .textCase(.uppercase)
                                .tracking(0.5)

                            TextField("", text: $name, prompt: Text("Enter name").foregroundStyle(Haya.Colors.textSageDim))
                                .font(HayaFont.bodyText)
                                .foregroundStyle(Haya.Colors.textCream)
                                .padding(Haya.Spacing.md)
                                .background(
                                    RoundedRectangle(cornerRadius: Haya.Radius.sm)
                                        .fill(Haya.Colors.glassBg)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: Haya.Radius.sm)
                                        .strokeBorder(Haya.Colors.glassBorder, lineWidth: 1)
                                )
                        }
                        .glassCard(padding: 20, radius: Haya.Radius.lg)

                        // Photo picker
                        VStack(alignment: .leading, spacing: Haya.Spacing.md) {
                            HStack {
                                Text("Photos")
                                    .font(HayaFont.label)
                                    .foregroundStyle(Haya.Colors.textSage)
                                    .textCase(.uppercase)
                                    .tracking(0.5)

                                Spacer()

                                Text("\(selectedImages.count) selected")
                                    .font(HayaFont.caption)
                                    .foregroundStyle(
                                        selectedImages.count >= 3
                                            ? Haya.Colors.accentGreen
                                            : Haya.Colors.textSageDim
                                    )
                            }

                            PhotosPicker(
                                selection: $selectedItems,
                                maxSelectionCount: 30,
                                matching: .images
                            ) {
                                HStack {
                                    Image(systemName: "photo.on.rectangle.angled")
                                    Text("Select Photos")
                                }
                                .font(HayaFont.pill)
                                .foregroundStyle(Haya.Colors.accentOrange)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(
                                    RoundedRectangle(cornerRadius: Haya.Radius.sm)
                                        .strokeBorder(Haya.Colors.accentOrange.opacity(0.3), lineWidth: 1.5)
                                )
                            }

                            if !selectedImages.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(0..<selectedImages.count, id: \.self) { idx in
                                            photoThumbnail(idx)
                                        }
                                    }
                                }
                            }

                            if isDetectingFaces {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .tint(Haya.Colors.accentOrange)
                                        .controlSize(.small)
                                    Text("Detecting faces...")
                                        .font(HayaFont.caption)
                                        .foregroundStyle(Haya.Colors.textSageDim)
                                }
                            }

                            if !pendingFacePicks.isEmpty && !isDetectingFaces {
                                Button {
                                    currentFacePickIndex = pendingFacePicks.first
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "person.crop.circle.badge.questionmark")
                                            .foregroundStyle(Haya.Colors.accentOrange)
                                        Text("\(pendingFacePicks.count) photo(s) need face selection")
                                            .font(HayaFont.caption)
                                            .foregroundStyle(Haya.Colors.accentOrange)
                                    }
                                }
                                .buttonStyle(.plain)
                            }

                            if selectedImages.count > 0 && selectedImages.count < 3 {
                                Text("Please select at least 3 photos")
                                    .font(HayaFont.caption)
                                    .foregroundStyle(Haya.Colors.accentRose)
                            }
                        }
                        .glassCard(padding: 20, radius: Haya.Radius.lg)

                        if isProcessing {
                            HStack(spacing: Haya.Spacing.md) {
                                ProgressView()
                                    .tint(Haya.Colors.accentOrange)
                                Text("Extracting embeddings...")
                                    .font(HayaFont.bodyText)
                                    .foregroundStyle(Haya.Colors.textSage)
                            }
                            .glassCard(padding: 16, radius: Haya.Radius.md)
                        }

                        if let error = errorMessage {
                            Text(error)
                                .font(HayaFont.caption)
                                .foregroundStyle(Haya.Colors.statusHide)
                                .glassCard(padding: 12, radius: Haya.Radius.sm)
                        }
                    }
                    .padding(Haya.Spacing.lg)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Add Person")
                        .font(HayaFont.headline)
                        .foregroundStyle(Haya.Colors.textCream)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Haya.Colors.textSage)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enroll") {
                        Task { await enroll() }
                    }
                    .foregroundStyle(Haya.Colors.accentOrange)
                    .fontWeight(.semibold)
                    .disabled(name.isEmpty || selectedImages.count < 3 || isProcessing || !pendingFacePicks.isEmpty || isDetectingFaces)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .onChange(of: selectedItems) { _, newItems in
                Task { await loadImages(from: newItems) }
            }
            .fullScreenCover(isPresented: Binding(
                get: { currentFacePickIndex != nil },
                set: { if !$0 { currentFacePickIndex = nil } }
            )) {
                if let idx = currentFacePickIndex, idx < selectedImages.count {
                    FacePickerOverlay(
                        image: selectedImages[idx],
                        personName: name.isEmpty ? "this person" : name,
                        onFaceSelected: { rect in
                            faceSelections[idx] = rect
                            pendingFacePicks.removeAll { $0 == idx }
                            // Auto-advance to next pending photo
                            if let next = pendingFacePicks.first {
                                currentFacePickIndex = next
                            } else {
                                currentFacePickIndex = nil
                            }
                        },
                        onCancel: {
                            currentFacePickIndex = nil
                        }
                    )
                }
            }
        }
    }

    // MARK: - Photo Thumbnail

    private func photoThumbnail(_ idx: Int) -> some View {
        let needsPick = pendingFacePicks.contains(idx)
        let hasPick = faceSelections.indices.contains(idx) && faceSelections[idx] != nil
        let faceCount = faceCounts.indices.contains(idx) ? faceCounts[idx] : 0

        return Image(uiImage: selectedImages[idx])
            .resizable()
            .scaledToFill()
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: Haya.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: Haya.Radius.sm)
                    .strokeBorder(
                        needsPick ? Haya.Colors.accentOrange :
                        hasPick ? Haya.Colors.accentGreen :
                        Haya.Colors.glassBorder,
                        lineWidth: needsPick || hasPick ? 2 : 1
                    )
            )
            .overlay(alignment: .bottomTrailing) {
                if faceCount > 1 {
                    Image(systemName: hasPick ? "checkmark.circle.fill" : "person.2.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(hasPick ? Haya.Colors.accentGreen : Haya.Colors.accentOrange)
                        .padding(4)
                        .background(Circle().fill(Haya.Colors.bgDeep))
                        .offset(x: 4, y: 4)
                }
            }
            .onTapGesture {
                if faceCount > 1 {
                    currentFacePickIndex = idx
                }
            }
    }

    // MARK: - Image Loading + Face Detection

    private func loadImages(from items: [PhotosPickerItem]) async {
        var images: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let uiImage = UIImage(data: data) {
                images.append(uiImage)
            }
        }
        selectedImages = images
        faceSelections = Array(repeating: nil, count: images.count)
        faceCounts = Array(repeating: 0, count: images.count)
        pendingFacePicks = []

        // Run face detection on all photos
        isDetectingFaces = true
        defer { isDetectingFaces = false }

        for (i, image) in images.enumerated() {
            guard let cgImage = image.cgImage else { continue }
            let request = VNDetectFaceRectanglesRequest()
            let orientation = CGImagePropertyOrientation(image.imageOrientation)
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
            do {
                try handler.perform([request])
                let count = request.results?.count ?? 0
                faceCounts[i] = count
                if count > 1 {
                    pendingFacePicks.append(i)
                }
            } catch {
                faceCounts[i] = 0
            }
        }

        // Auto-show face picker if any multi-face photos
        if let first = pendingFacePicks.first, !name.isEmpty {
            currentFacePickIndex = first
        }
    }

    // MARK: - Enrollment

    private func enroll() async {
        isProcessing = true
        errorMessage = nil
        defer { isProcessing = false }

        let ciImages: [CIImage] = selectedImages.compactMap { uiImage in
            guard let cgImage = uiImage.cgImage else { return nil }
            return CIImage(cgImage: cgImage)
        }

        do {
            let enrollment = try await pipeline.identifier.enroll(
                name: name,
                images: ciImages,
                faceSelections: faceSelections
            )
            onEnrolled(enrollment.name, selectedImages.count)
            try? await Task.sleep(for: .seconds(0.5))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

