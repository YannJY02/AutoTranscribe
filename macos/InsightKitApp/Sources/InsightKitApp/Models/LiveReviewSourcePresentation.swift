import Foundation

struct LiveReviewSourcePresentation: Equatable {
    let primaryMediaURL: URL?
    let statusMessage: String?

    var showsPrimaryMedia: Bool {
        primaryMediaURL != nil
    }

    static func make(
        mediaURL: URL?,
        reviewSourceMediaURL: URL?,
        statusMessage: String?
    ) -> LiveReviewSourcePresentation {
        if let mediaURL,
           isVisualMedia(mediaURL),
           let reviewSourceMediaURL,
           reviewSourceMediaURL != mediaURL,
           isAudioMedia(reviewSourceMediaURL) {
            return LiveReviewSourcePresentation(
                primaryMediaURL: mediaURL,
                statusMessage: statusMessage
            )
        }

        return LiveReviewSourcePresentation(
            primaryMediaURL: reviewSourceMediaURL ?? mediaURL,
            statusMessage: statusMessage
        )
    }

    private static func isVisualMedia(_ url: URL) -> Bool {
        ["mp4", "mov", "mkv"].contains(url.pathExtension.lowercased())
    }

    private static func isAudioMedia(_ url: URL) -> Bool {
        ["wav", "m4a", "mp3", "aac", "flac", "caf"].contains(url.pathExtension.lowercased())
    }
}
