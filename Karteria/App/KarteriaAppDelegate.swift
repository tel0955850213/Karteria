import CloudKit
import UIKit

final class KarteriaAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        TrustedReviewService.accept(cloudKitShareMetadata)
    }
}
