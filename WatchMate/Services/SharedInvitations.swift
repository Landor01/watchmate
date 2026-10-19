import CloudKit
import SwiftUI
import UIKit

final class SharingAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = SharingSceneDelegate.self
        return configuration
    }

    func application(_ application: UIApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        SharingSceneDelegate.accept(metadata)
    }
}

final class SharingSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        if let metadata = options.cloudKitShareMetadata { Self.accept(metadata) }
    }

    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Self.accept(metadata)
    }

    @MainActor static func accept(_ metadata: CKShare.Metadata) {
        Task {
            do {
                let store = try AppServices.shared().store
                store.sharedShows.activate(accountID: store.settings.traktAccountID)
                await store.sharedShows.accept(metadata)
            } catch {
                // A store failure is surfaced by the app's existing startup error handling.
            }
        }
    }
}

struct HouseholdSharingSheet: UIViewControllerRepresentable {
    let share: CKShare
    let service: SharedShows
    let list: HouseholdList

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: service.container)
        controller.availablePermissions = [.allowPrivate, .allowReadWrite]
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UICloudSharingController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(service: service, list: list) }

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let service: SharedShows
        let list: HouseholdList
        init(service: SharedShows, list: HouseholdList) {
            self.service = service
            self.list = list
        }

        func itemTitle(for csc: UICloudSharingController) -> String? { list.name }

        func itemThumbnailData(for csc: UICloudSharingController) -> Data? {
            SharedListAvatar.image(name: list.name, photoData: list.photoData).pngData()
        }

        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            service.errorMessage = error.localizedDescription
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            Task { await service.refresh() }
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            Task { await service.refresh() }
        }
    }
}
