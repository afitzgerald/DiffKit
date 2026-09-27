import SwiftUI

/// The default diff colours. `PatchTheme` starts from these.
public enum DiffTheme {
    public static let added = Color.green
    public static let removed = Color.red
    public static let addedBG = Color.green.opacity(0.14)
    public static let removedBG = Color.red.opacity(0.14)
}
