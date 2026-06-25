import Foundation

struct LiveReviewSourcePresentation: Equatable {
    let primaryMediaURL: URL?
    let supplementalAudioURL: URL?
    let statusMessage: String?

    var showsPrimaryMedia: Bool {
        primaryMediaURL != nil
    }

    var showsSupplementalAudio: Bool {
        supplementalAudioURL != nil
    }

    static func make(
        mediaURL: URL?,
        reviewSourceMediaURL: URL?,
        statusMessage: String?
    ) -> LiveReviewSourcePresentation {
        if let mediaURL, isVisualMedia(mediaURL) {
            let supplementalAudioURL: URL?
            if let reviewSourceMediaURL,
               reviewSourceMediaURL != mediaURL,
               isAudioMedia(reviewSourceMediaURL) {
                supplementalAudioURL = reviewSourceMediaURL
            } else {
                supplementalAudioURL = nil
            }

            return LiveReviewSourcePresentation(
                primaryMediaURL: mediaURL,
                supplementalAudioURL: supplementalAudioURL,
                statusMessage: statusMessage
            )
        }

        return LiveReviewSourcePresentation(
            primaryMediaURL: reviewSourceMediaURL ?? mediaURL,
            supplementalAudioURL: nil,
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
