import SwiftUI

/// SwiftUI's `@ViewState` under another name. In the macOS 27 SDK the `@ViewState` attribute is
/// expanded by a macro plugin that ships with Xcode but not with the Command Line Tools this
/// project builds with. Spelling the attribute differently selects the `State` property wrapper
/// itself — the same type with the same behaviour — so the app builds without Xcode.
typealias ViewState<Value> = SwiftUI.State<Value>
