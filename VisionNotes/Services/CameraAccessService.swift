import AVFoundation
import Foundation
import UIKit

/// Camera availability and permission, kept out of the views.
enum CameraAccess {
    enum State: Equatable {
        case unavailable
        case notDetermined
        case denied
        case authorized
    }

    /// The Simulator has no camera, so this is `false` there.
    static var isCameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    static var state: State {
        guard isCameraAvailable else { return .unavailable }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    /// Asks for camera access, returning the resulting state.
    static func requestAccess() async -> State {
        guard isCameraAvailable else { return .unavailable }
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        return granted ? .authorized : .denied
    }

    @MainActor
    static func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString),
              UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
    }
}
