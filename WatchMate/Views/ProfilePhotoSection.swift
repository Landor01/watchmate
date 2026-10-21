import SwiftUI
import PhotosUI
import UIKit
import AVFoundation

struct ProfilePhotoSection: View {
    @Environment(AppStore.self) private var store
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var imageToCrop: ProfilePhotoSelection?
    @State private var capturedImage: UIImage?
    @State private var showCamera = false
    @State private var confirmingPhotoRemoval = false
    @State private var cameraDenied = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var requestingCamera = false
    @State private var cameraPresentationPending = false

    var body: some View {
        Section {
            VStack(spacing: 12) {
                ProfilePhotoView(image: store.settings.profileImage, size: 96)
                    .accessibilityLabel("Profile photo")
                    .overlay(alignment: .topTrailing) {
                        if store.settings.profileImage != nil {
                            Button { confirmingPhotoRemoval = true } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title2)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.75))
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove profile photo")
                            .accessibilityHint("Asks for confirmation before restoring the generic person icon.")
                            .offset(x: 12, y: -12)
                            .popover(isPresented: $confirmingPhotoRemoval, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                                VStack(alignment: .leading, spacing: 16) {
                                    Text("Remove profile photo?").font(.headline)
                                    Text("Your photo will be replaced with the generic person icon.")
                                        .font(.subheadline)
                                    HStack {
                                        Button("Cancel", role: .cancel) { confirmingPhotoRemoval = false }
                                        Spacer()
                                        Button("Remove photo", role: .destructive) {
                                            confirmingPhotoRemoval = false
                                            do { try store.settings.removeProfileImage() }
                                            catch { store.errorMessage = error.localizedDescription }
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                }
                                .padding()
                                .frame(idealWidth: 300, maxWidth: 340)
                                .presentationCompactAdaptation(.popover)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                HStack {
                    photoControls
                }
                .buttonStyle(.borderless)
            }
            .frame(maxWidth: .infinity)
            .task(id: requestingCamera) {
                guard requestingCamera else { return }
                defer { requestingCamera = false }
                let allowed: Bool
                switch AVCaptureDevice.authorizationStatus(for: .video) {
                case .authorized:
                    allowed = true
                case .notDetermined:
                    allowed = await AVCaptureDevice.requestAccess(for: .video)
                default:
                    allowed = false
                }
                guard !Task.isCancelled else { return }
                if allowed {
                    cameraPresentationPending = true
                } else {
                    cameraDenied = true
                }
            }
            .task(id: cameraPresentationPending && scenePhase == .active) {
                guard cameraPresentationPending, scenePhase == .active else { return }
                // Let the permission alert's lifecycle update finish before presenting another controller.
                await Task.yield()
                guard !Task.isCancelled, scenePhase == .active else { return }
                cameraPresentationPending = false
                showCamera = true
            }
            .onDisappear {
                cameraPresentationPending = false
            }
            .task(id: selectedPhotoItem) {
                guard let item = selectedPhotoItem else { return }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else {
                        throw APIError.message("This photo could not be opened. Please choose another photo.")
                    }
                    try Task.checkCancellation()
                    imageToCrop = ProfilePhotoSelection(image: image)
                } catch is CancellationError {
                } catch {
                    store.errorMessage = error.localizedDescription
                }
            }
            .sheet(item: $imageToCrop, onDismiss: { selectedPhotoItem = nil }) { selection in
                CropperView(originalImage: selection.image) { image in
                    do {
                        try store.settings.saveProfileImage(image)
                    } catch {
                        store.errorMessage = error.localizedDescription
                    }
                    imageToCrop = nil
                } onCancel: {
                    imageToCrop = nil
                }
            }
            .fullScreenCover(isPresented: $showCamera, onDismiss: {
                if let image = capturedImage {
                    imageToCrop = ProfilePhotoSelection(image: image)
                    capturedImage = nil
                }
            }) {
                CameraCaptureView { image in
                    capturedImage = image
                    showCamera = false
                } onCancel: {
                    showCamera = false
                }
                .ignoresSafeArea()
            }
            .alert("Camera access needed", isPresented: $cameraDenied) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Allow camera access in Settings to take a profile photo.")
            }
        }
    }

    @ViewBuilder
    private var photoControls: some View {
        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
            Label("Choose Photo", systemImage: "photo")
        }
        .accessibilityLabel("Choose profile photo")
        Spacer(minLength: 16)
        Button {
            requestingCamera = true
        } label: {
            Label("Take Photo", systemImage: "camera")
        }
        .disabled(requestingCamera || cameraPresentationPending || showCamera || !UIImagePickerController.isSourceTypeAvailable(.camera))
        .accessibilityLabel("Take profile photo")
    }
}

private struct ProfilePhotoSelection: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct ProfilePhotoView: View {
    let image: UIImage?
    let size: CGFloat

    var body: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        }
    }
}

// Adapted from WeightMatePro's profile photo controls.
struct CameraCaptureView: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) { }

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onImage: (UIImage) -> Void
        let onCancel: () -> Void

        init(onImage: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onImage = onImage
            self.onCancel = onCancel
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                onImage(image)
            } else {
                onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}


struct CropperView: View {
    let originalImage: UIImage
    let onSave: (UIImage) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    // The crop square will be based on screen width minus padding
    private let padding: CGFloat = 24

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) - padding * 2
            ZStack {
                Color.black.ignoresSafeArea()

                // Image with gestures
                imageView(size: CGSize(width: side, height: side))
                    .frame(width: side, height: side)
                    .clipped()
                    .overlay(circleMask(diameter: side).allowsHitTesting(false))
            }
            .overlay(toolbar(side: side), alignment: .top)
            .overlay(bottomBar(side: side, in: geo.size), alignment: .bottom)
        }
    }

    private func imageView(size: CGSize) -> some View {
        let img = Image(uiImage: originalImage)
            .resizable()
            .scaledToFill()
        return img
            .scaleEffect(scale)
            .offset(offset)
            .gesture(dragGesture())
            .gesture(magnificationGesture())
            .background(Color.black)
            .accessibilityLabel("Profile photo crop")
            .accessibilityValue("\(Int(scale * 100)) percent zoom")
            .accessibilityHint("Swipe up or down to zoom. Use the available actions to move the photo.")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    updateScale(by: 0.25)
                case .decrement:
                    updateScale(by: -0.25)
                @unknown default:
                    break
                }
            }
            .accessibilityAction(named: "Move left") {
                moveImage(horizontal: -12, vertical: 0)
            }
            .accessibilityAction(named: "Move right") {
                moveImage(horizontal: 12, vertical: 0)
            }
            .accessibilityAction(named: "Move up") {
                moveImage(horizontal: 0, vertical: -12)
            }
            .accessibilityAction(named: "Move down") {
                moveImage(horizontal: 0, vertical: 12)
            }
    }

    private func circleMask(diameter: CGFloat) -> some View {
        ZStack {
            Color.black.opacity(0.6)
            Circle()
                .blendMode(.destinationOut)
                .frame(width: diameter, height: diameter)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.9), lineWidth: 1)
                        .frame(width: diameter, height: diameter)
                )
        }
        .compositingGroup()
        .allowsHitTesting(false)
    }

    private func toolbar(side: CGFloat) -> some View {
        HStack {
            Button("Cancel") {
                onCancel()
                dismiss()
            }
            Spacer()
            Text("Move and Scale")
                .foregroundStyle(.primary)
                .bold()
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button("Choose") {
                if let cropped = cropToSquare(targetPixels: side * displayScale) {
                    onSave(cropped)
                }
                dismiss()
            }
        }
        .padding()
        .background(Color(uiColor: .systemBackground))
    }

    private func bottomBar(side: CGFloat, in container: CGSize) -> some View {
        HStack {
            Spacer()
        }
        .frame(height: 44)
        .padding(.bottom, 16)
        .background(Color.clear)
    }

    private func dragGesture() -> some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height)
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }

    private func magnificationGesture() -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = max(1.0, min(5.0, lastScale * value))
            }
            .onEnded { _ in
                lastScale = scale
            }
    }

    private func updateScale(by amount: CGFloat) {
        scale = max(1.0, min(5.0, scale + amount))
        lastScale = scale
    }

    private func moveImage(horizontal: CGFloat, vertical: CGFloat) {
        offset = CGSize(
            width: offset.width + horizontal,
            height: offset.height + vertical
        )
        lastOffset = offset
    }

    private func cropToSquare(targetPixels: CGFloat) -> UIImage? {
        // Render the visible square area into an image using the provided target pixel size
        let sidePoints = targetPixels / displayScale
        let renderSize = CGSize(width: sidePoints, height: sidePoints)

        let renderer = ImageRenderer(content:
            Image(uiImage: originalImage)
                .resizable()
                .scaledToFill()
                .scaleEffect(scale)
                .offset(offset)
                .frame(width: renderSize.width, height: renderSize.height)
                .clipped()
        )
        renderer.scale = displayScale
        return renderer.uiImage
    }
}


#if DEBUG

#Preview("Profile photo settings") {
    PreviewHost { data in
        Form { ProfilePhotoSection() }
    }
}

#Preview("Profile avatar") {
    PreviewHost { data in
        ProfilePhotoView(image: nil, size: 96)
    }
}

#Preview("Photo cropper") {
    PreviewHost { data in
        if let image = DemoLibrary.image(for: data.show.posterPath) { CropperView(originalImage: image, onSave: { _ in }, onCancel: {}) }
    }
}

#Preview("Camera") {
    PreviewHost { data in
        if UIImagePickerController.isSourceTypeAvailable(.camera) { CameraCaptureView(onImage: { _ in }, onCancel: {}) } else { ContentUnavailableView("Camera unavailable in previews", systemImage: "camera", description: Text("Use a device to test photo capture.")) }
    }
}
#endif
