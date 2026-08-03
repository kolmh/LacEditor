import AppKit

@main
enum EditorInteractionVerification {
    static func main() {
        let textView = LacTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        textView.string = "first\nsecond\nthird"

        var trackingUpdates = 0
        var observedTrackingRange: NSRange?
        textView.selectionTrackingHandler = {
            trackingUpdates += 1
            observedTrackingRange = textView.selectedRange()
        }
        let draggedRange = NSRange(location: 0, length: 12)
        textView.setSelectedRange(
            draggedRange,
            affinity: .downstream,
            stillSelecting: true
        )
        require(
            observedTrackingRange == draggedRange,
            "drag selection is applied before the tracking callback"
        )
        require(
            trackingUpdates == 1,
            "drag selection triggers an immediate tracking update"
        )

        textView.setSelectedRange(
            NSRange(location: 0, length: 0),
            affinity: .downstream,
            stillSelecting: false
        )
        require(
            trackingUpdates == 1,
            "completed or programmatic selections use the normal delegate path"
        )

        print("Editor interaction verification passed")
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            fatalError("Verification failed: \(message)")
        }
    }
}
