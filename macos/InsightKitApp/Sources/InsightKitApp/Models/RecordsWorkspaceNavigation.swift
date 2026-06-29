import Combine
import Foundation

final class RecordsWorkspaceNavigation: ObservableObject {
    @Published private(set) var selectedRecordID: String?

    var isReviewingRecord: Bool {
        selectedRecordID != nil
    }

    func openReview(recordID: String) {
        selectedRecordID = recordID
    }

    func closeReview() {
        selectedRecordID = nil
    }
}

enum WorkflowPrimaryNavigationAction: Equatable {
    case none
    case home
    case recordsList

    var title: String {
        switch self {
        case .none:
            return ""
        case .home:
            return "返回首页"
        case .recordsList:
            return "返回列表"
        }
    }

    var accessibilityID: String {
        switch self {
        case .none:
            return ""
        case .home:
            return "workflow_back_home"
        case .recordsList:
            return "workflow_back_records_list"
        }
    }
}
