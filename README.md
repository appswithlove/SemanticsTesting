# SemanticsTesting

In-process UI testing for SwiftUI through the real accessibility tree.

`SemanticsTester` hosts a view in a `UIWindow` inside your unit-test process, turns on the same
process-wide accessibility automation flag XCUITest uses, and lets you query and drive what
VoiceOver would see: labels, values, identifiers, traits, buttons, toggles, custom actions,
text fields, menus, sheets. No UI-test target, no app relaunch, no view-hierarchy reflection.
Tests run in tens of milliseconds and fail with a dump of the accessibility tree.

```swift
import SemanticsTesting
import SwiftUI
import Testing

@Suite(.serialized)
@MainActor
struct CounterViewTests {
    @Test func incrementUpdatesCount() throws {
        let tester = SemanticsTester { CounterView() }
        defer { tester.tearDown() }

        try tester.expect("Count: 0")
        try tester.tap("Increment")
        try tester.expect("Count: 1")
    }
}
```

Because it walks the accessibility tree, a view that is untestable is also a view VoiceOver users
cannot use. The two problems get fixed together.

## Requirements

- iOS 17+ (simulator or device). UIKit only, no macOS.
- Swift 6 language mode, Xcode 26+.
- Swift Testing or XCTest. The library depends on neither.

## Installation

```swift
.package(url: "https://github.com/appswithlove/SemanticsTesting", from: "0.1.0")
```

Add `SemanticsTesting` to your **test** targets only. It links nothing but SwiftUI and UIKit and
never reaches production code.

## The contract

These rules come from running the tester against several hundred view tests. Break them and you
get flaky trees, hangs, or "0 tests" runs.

1. **`@Suite(.serialized)` and `@MainActor` on every suite that hosts a view.** The tester owns one
   key window per process. Swift Testing interleaves suites onto the MainActor, and two live
   testers fight over the key window.
2. **`defer { tester.tearDown() }` immediately after creating a tester.** Tear-down releases the
   window, dismisses presentations, restores the previous key window, and opens the gate for the
   next tester.
3. **Disable parallelization for the test bundle in the scheme.** Parallel Swift Testing suspends
   an async test at an `await` while another suite spins the run loop in `pump()`. The suspended
   test then cannot resume. In Xcode: scheme > Test > Options > uncheck "Execute in parallel".
   In Tuist: `parallelization: .disabled` on the testable target.
4. **Use the async API when the effect crosses an `await`.** `pump()` blocks the MainActor. A
   `Button { Task { await … } }` makes no progress inside it. Use `SemanticsTester.make`,
   `tapAsync`, `expectAsync`, `expectGoneAsync`, `waitAsync`, and `settle` instead.
5. **Provide a host app for presentation and control dispatch.** See below.

## Host app

SwiftUI needs a live `UIApplication` with a foreground-active scene for two things:

- Running a `present()` transition: `.sheet`, `.fullScreenCover`, `Menu`, popovers, alerts,
  confirmation dialogs.
- Dispatching UIControl actions: a `TextField` syncing typed text back to its binding, toolbar
  bar buttons.

Without a host, `SemanticsTester` falls back to a detached fixed-size window. Queries, taps on
SwiftUI buttons and toggles, custom actions, scrolling and the async API all work host-less.
Presentation and text entry do not.

A Swift package cannot declare a test host, so the host lives in your project. Create an
empty iOS app target and set it as the host application of your test bundles:

```swift
import SwiftUI

/// Deliberately empty and dependency-free: hosting the module tests stays cheap.
@main
struct SemanticsTestHostApp: App {
    var body: some Scene {
        WindowGroup {
            Color.clear
        }
    }
}
```

If your app ships custom fonts, register them in the host's `Info.plist` under `UIAppFonts` too.
Without them the host falls back to the system face, and a view that wraps or truncates in the
app measures differently in the test.

The tester attaches to the host's scene when one exists, excludes the host's pre-existing windows
from queries, and includes any window that appears after hosting began. That is where menus,
popovers and context menus render.

## API overview

Queries return `SemanticsNode` values: `label`, `value`, `identifier`, `traits`, `isEnabled`,
`customActionNames`, `owner` (nearest `UIView`), `summary`.

| Category | Synchronous | Async |
|---|---|---|
| Create | `SemanticsTester { view }`, `SemanticsTester(hosting:)` | `SemanticsTester.make { view }` |
| Find now | `nodes`, `node(_:)`, `node(id:)`, `node(value:)`, `node(containing:)` | |
| Wait | `expect(_:)`, `expect(id:)`, `expect(containing:)`, `expectGone(_:)`, `wait(where:)` | `expectAsync`, `expectGoneAsync`, `waitAsync` |
| Act | `tap(_:)`, `type(_:into:)`, `forceActivate(_:)`, `node.activate()`, `node.performCustomAction(named:)`, `node.increment()` / `decrement()` | `tapAsync(_:)` |
| Time | `pump(_:)` | `settle(_:)` |
| Debug | `dump()`, `SemanticsWalker.dump(_:)` | |

Waits scroll every scroll view down one step after a third of the timeout, so lazy rows below
the fold materialize the way they would for a user.

`tap` resolves a label first inside the frontmost presented sheet, then in the rest of the tree,
prefers buttons, and refuses disabled controls. `forceActivate` skips the enabled check, for
negative tests only.

Set `SEMANTICS_DEMO_PAUSE=1` (seconds; via `TEST_RUNNER_SEMANTICS_DEMO_PAUSE` when launching
through xcodebuild) to slow interactions down enough to watch them on the simulator.

## Private API

This is a test-only library and uses private UIKit and Accessibility API to do its job. Never
link it into an app you submit.

- `_AXSSetAutomationEnabled` from `libAccessibility.dylib`. Turns on the accessibility node tree
  SwiftUI otherwise leaves empty.
- `UIApplication.sharedApplication` via KVC, to attach to a host scene without a compile-time
  dependency on `UIApplication.shared`.
- `_dismissWithAction:` and `_invokeHandlersForAction:` on `UIAlertController`, so alert and
  confirmation-dialog buttons fire the way a tap does.
- `displayedMenu` on the context-menu interaction delegate and `handler` on `UIAction`, to
  activate menu items that never enter the accessibility tree.

Each of these can break with an iOS release. The test suite is the canary.

## Running the package tests

```sh
xcodebuild test -scheme SemanticsTesting -destination 'platform=iOS Simulator,name=iPhone 17'
```

`swift test` does not work: the code is UIKit-only. The package tests run host-less and cover
the walker, node model, queries, taps, waits, scrolling, error reporting and the async API.
Presentation and text entry are covered by the consuming project's hosted test bundles.

## License

MIT. See `LICENSE`.
