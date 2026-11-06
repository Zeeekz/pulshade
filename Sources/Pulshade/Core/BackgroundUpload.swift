#if os(iOS)
import BackgroundTasks
import Foundation

/// Keeps a story going out after you leave Pulshade.
///
/// A video story is megabytes for every person it goes to, which is minutes on a phone, and iOS stops an app within
/// seconds of it leaving the screen. So while a story is uploading, iOS is asked to let the work carry on. It shows
/// its own progress for it outside the app (which you can stop from there), and may end it early when the phone is
/// busy or the upload stalls; whatever is left then goes the next time Pulshade is open.
@MainActor
enum BackgroundUpload {
    nonisolated static let taskID = "app.pulshade.ios.upload"

    private static var task: BGContinuedProcessingTask?
    /// Asked for and not over yet, whether or not iOS has started it.
    private(set) static var isWanted = false
    /// Run when iOS, or the person from its progress display, ends it before the upload is done.
    static var onEnded: (() -> Void)?

    /// Called once at launch.
    nonisolated static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let task = task as? BGContinuedProcessingTask else { return task.setTaskCompleted(success: false) }
            Task { @MainActor in started(task) }
        }
    }

    /// Asks iOS to keep the upload going. Only while Pulshade is in front: iOS takes the request from an app the
    /// person is using, not from one already in the background. Does nothing if it's already asked for.
    static func begin(title: String, subtitle: String) {
        guard !isWanted else { return }
        let request = BGContinuedProcessingTaskRequest(identifier: taskID, title: title, subtitle: subtitle)
        // Now or not at all: an upload that waits its turn behind other apps' work isn't what was asked for.
        request.strategy = .fail
        guard (try? BGTaskScheduler.shared.submit(request)) != nil else { return }
        isWanted = true
    }

    /// How far the upload has got, 0...1. iOS shows it, and ends work that never moves.
    static func report(_ progress: Double) {
        guard let task else { return }
        let done = Int64((min(max(progress, 0), 1) * 1000).rounded())
        if done > task.progress.completedUnitCount { task.progress.completedUnitCount = done }
    }

    /// The upload is over: iOS is told, and its progress display goes.
    static func finish() {
        guard isWanted else { return }
        isWanted = false
        task?.progress.completedUnitCount = 1000
        task?.setTaskCompleted(success: true)
        task = nil
    }

    private static func started(_ new: BGContinuedProcessingTask) {
        // The upload finished before iOS got round to starting this.
        guard isWanted, task == nil else { return new.setTaskCompleted(success: true) }
        new.progress.totalUnitCount = 1000
        new.expirationHandler = {
            Task { @MainActor in
                guard task === new else { return }
                // Nothing is lost when iOS ends this early: what is left goes out the next time Pulshade is open. So it
                // isn't reported as a failure, which would leave a "Task failed" mark on the phone with nothing wrong.
                new.setTaskCompleted(success: true)
                task = nil
                isWanted = false
                onEnded?()
            }
        }
        task = new
    }
}
#endif
