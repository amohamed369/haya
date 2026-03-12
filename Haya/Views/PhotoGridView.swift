import SwiftUI
import Photos

struct PhotoGridView: View {
    @EnvironmentObject var pipeline: Pipeline
    @Binding var showHidden: Bool

    @State private var assets: [PHAsset] = []
    @State private var selectedAsset: PHAsset?
    @State private var authorizationStatus: PHAuthorizationStatus = .notDetermined

    /// Use pipeline's scan results (populated by ScanEngine).
    private var filterResults: [String: PhotoFilterResult] {
        pipeline.scanResults
    }

    private let columns = [GridItem(.adaptive(minimum: 105), spacing: 3)]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: Haya.Spacing.xs) {
                Text(greetingText)
                    .font(HayaFont.caption)
                    .foregroundStyle(Haya.Colors.textSage)
                    .textCase(.uppercase)
                    .tracking(0.4)

                Text("Your Photos")
                    .font(HayaFont.largeTitle)
                    .foregroundStyle(Haya.Colors.textCream)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Haya.Spacing.lg)
            .padding(.top, Haya.Spacing.md)
            .padding(.bottom, Haya.Spacing.md)

            if authorizationStatus == .authorized || authorizationStatus == .limited {
                ScrollView {
                    // Stats bar
                    HStack(spacing: Haya.Spacing.sm) {
                        statPill(count: assets.count, label: "Total")
                        statPill(
                            count: filterResults.values.filter { $0.overallDecision == .hide }.count,
                            label: "Hidden",
                            color: Haya.Colors.accentOrange
                        )
                        statPill(
                            count: filterResults.values.filter { $0.overallDecision == .keep }.count,
                            label: "Visible",
                            color: Haya.Colors.accentTeal
                        )
                    }
                    .padding(.horizontal, Haya.Spacing.lg)
                    .padding(.bottom, Haya.Spacing.md)

                    // Photo grid
                    LazyVGrid(columns: columns, spacing: 3) {
                        ForEach(assets, id: \.localIdentifier) { asset in
                            PhotoThumbnailView(
                                asset: asset,
                                filterResult: filterResults[asset.localIdentifier],
                                showHidden: showHidden
                            )
                            .onTapGesture {
                                selectedAsset = asset
                            }
                        }
                    }
                    .padding(.horizontal, 3)
                    .padding(.bottom, Haya.Spacing.tabClearance)
                }
                .sheet(item: Binding(
                    get: { selectedAsset.map { IdentifiableAsset(asset: $0) } },
                    set: { selectedAsset = $0?.asset }
                )) { item in
                    PhotoDetailView(asset: item.asset)
                        .environmentObject(pipeline)
                }
            } else if authorizationStatus == .denied {
                Spacer()
                VStack(spacing: Haya.Spacing.md) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(Haya.Colors.textSageDim)
                    Text("No Photo Access")
                        .font(HayaFont.title3)
                        .foregroundStyle(Haya.Colors.textCream)
                    Text("Enable photo access in Settings.")
                        .font(HayaFont.bodyText)
                        .foregroundStyle(Haya.Colors.textSage)
                }
                Spacer()
            } else {
                Spacer()
                ProgressView()
                    .tint(Haya.Colors.accentOrange)
                Spacer()
            }
        }
        .task {
            await requestAccess()
            loadPhotos()
        }
    }

    private func statPill(count: Int, label: String, color: Color = Haya.Colors.textSage) -> some View {
        HStack(spacing: 6) {
            Text("\(count)")
                .font(HayaFont.heading(14, weight: .semibold))
                .foregroundStyle(color)
            Text(label)
                .font(HayaFont.caption2)
                .foregroundStyle(Haya.Colors.textSageDim)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule().fill(Haya.Colors.glassBg)
        )
        .overlay(
            Capsule().strokeBorder(Haya.Colors.glassBorder, lineWidth: 1)
        )
    }

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private func requestAccess() async {
        authorizationStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    private func loadPhotos() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 200
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var loaded: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            loaded.append(asset)
        }
        assets = loaded
    }
}

// MARK: - Thumbnail View

struct PhotoThumbnailView: View {
    let asset: PHAsset
    let filterResult: PhotoFilterResult?
    let showHidden: Bool

    @State private var thumbnail: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let thumb = thumbnail {
                    Image(uiImage: thumb)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.width)
                        .clipped()
                } else {
                    SkeletonGridCell()
                }

                // Hidden overlay
                if let result = filterResult, result.overallDecision == .hide, !showHidden {
                    ZStack {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                        Rectangle()
                            .fill(Haya.Colors.bgPrimaryDark.opacity(0.6))
                        Image(systemName: "eye.slash.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Haya.Colors.textSageDim)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.width)
            .clipShape(RoundedRectangle(cornerRadius: Haya.Radius.xxs))
        }
        .aspectRatio(1, contentMode: .fit)
        .task {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat // Must be single-callback; .opportunistic calls twice → crashes continuation
        options.isNetworkAccessAllowed = true

        let size = CGSize(width: 200, height: 200)

        thumbnail = await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: size, contentMode: .aspectFill, options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !isDegraded, !resumed else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }
}

// MARK: - Helpers

struct IdentifiableAsset: Identifiable {
    let id: String
    let asset: PHAsset

    init(asset: PHAsset) {
        self.id = asset.localIdentifier
        self.asset = asset
    }
}
