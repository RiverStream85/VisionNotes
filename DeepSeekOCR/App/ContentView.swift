import PhotosUI
import SwiftUI

struct ContentView: View {
    @Bindable var viewModel: OCRViewModel
    @State private var photoItem: PhotosPickerItem?
    @State private var importingFile = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    hero
                    imagePanel
                    controls
                    resultPanel
                }
                .padding(18)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("DeepSeek OCR")
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(
                isPresented: $importingFile,
                allowedContentTypes: [.image],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    Task { await viewModel.loadFile(url) }
                } else if case .failure(let error) = result {
                    viewModel.errorMessage = error.localizedDescription
                }
            }
            .task(id: photoItem) {
                await viewModel.loadPhotoItem(photoItem)
                photoItem = nil
            }
            .alert("DeepSeek OCR", isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "Unknown error")
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Private OCR, on this device")
                .font(.title2.weight(.semibold))
            Text("DeepSeek-OCR-2 · 3B MoE · Q4/Q8 · Metal")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Label("Images never leave this device", systemImage: "lock.shield")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.green)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var imagePanel: some View {
        Group {
            if let image = viewModel.selectedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 360)
                    .frame(maxWidth: .infinity)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(.quaternary, lineWidth: 1)
                    }
            } else {
                ContentUnavailableView(
                    "No image selected",
                    systemImage: "text.viewfinder",
                    description: Text("Choose a photo, an image file, or the bundled math test page.")
                )
                .frame(maxWidth: .infinity, minHeight: 240)
                .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Photos", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isBusy)

                Button { importingFile = true } label: {
                    Label("Files", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isBusy)
            }

            Button { Task { await viewModel.loadMathFixture() } } label: {
                Label("Use math test page", systemImage: "function")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isBusy)

            Picker("OCR output", selection: $viewModel.mode) {
                ForEach(OCRMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.isBusy)

            Picker("Vision quality", selection: $viewModel.performanceMode) {
                ForEach(OCRPerformanceMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.isBusy)

            Text(viewModel.performanceMode.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if viewModel.isRunning {
                Button(role: .cancel) { viewModel.cancelOCR() } label: {
                    HStack {
                        ProgressView()
                        Text("Cancel OCR")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.bordered)
            } else {
                Button { viewModel.runOCR() } label: {
                    HStack {
                        if viewModel.isPreparingImage {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "text.viewfinder")
                        }
                        Text(viewModel.isPreparingImage ? "Preparing image…" : "Recognize locally")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.selectedImage == nil || viewModel.isPreparingImage)
            }

            Text(viewModel.status)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let metrics = viewModel.metrics {
                Text(metrics.summary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var resultPanel: some View {
        if !viewModel.resultText.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("OCR result")
                        .font(.headline)
                    Spacer()
                    ShareLink(item: viewModel.resultText) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    Button {
                        UIPasteboard.general.string = viewModel.resultText
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
                TextEditor(text: $viewModel.resultText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 280)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(16)
            .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}
