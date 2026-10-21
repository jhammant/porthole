import CoreGraphics

// Porthole (docs/porthole-plan.md): what the coordinator's own switches ask of Porthole.
extension StreamCoordinator {
    /// The tiles' rectangle on screen, in global points, while tiles stream: where input lands.
    var portholeTilesRect: CGRect? { portholeTiles.rectOnScreen }
}
