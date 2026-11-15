import CoreGraphics
import SwiftUI
import Testing
@testable import ShellUI
#if os(iOS)
import UIKit
#endif

@Suite struct NativeChoiceControlTests {
    @Test func controllerSelectionAdvancesWrapsAndHandlesMissingValues() {
        let options = [SettingOption("over", "Over"), SettingOption("below", "Below")]
        #expect(NativeChoiceControl.nextValue(options, after: "over") == "below")
        #expect(NativeChoiceControl.nextValue(options, after: "below") == "over")
        #expect(NativeChoiceControl.nextValue(options, after: "unknown") == "over")
        #expect(NativeChoiceControl.nextValue([], after: "unknown") == nil)
    }

    @Test func firstFrameWithUnknownWidthResolvesInlineShortChoicesAsSegmented() {
        let options = [SettingOption("handheld", "Handheld"), SettingOption("docked", "Docked")]
        #expect(NativeChoiceControl.usesSegmentedControl(
            options: options, menuOnly: false, inline: true, width: nil, textScale: 1
        ))
        #expect(!NativeChoiceControl.usesSegmentedControl(
            options: options, menuOnly: false, inline: true, width: 280, textScale: 1
        ))
        #expect(NativeChoiceControl.usesSegmentedControl(
            options: options, menuOnly: false, inline: true, width: 360, textScale: 1
        ))
        #expect(!NativeChoiceControl.usesSegmentedControl(
            options: options, menuOnly: true, inline: true, width: 360, textScale: 1
        ))
        let five = (1...5).map { SettingOption("\($0)", "\($0)") }
        #expect(!NativeChoiceControl.usesSegmentedControl(
            options: five, menuOnly: false, inline: true, width: nil, textScale: 1
        ))
    }

    @Test func inlineSegmentedControlClampsToCompactMinimumWidthInsteadOfExpandingRow() {
        let shortIntrinsic = CGSize(width: 142, height: 32)
        #expect(NativeCreamSegmentedSizing.measuredSize(
            proposal: ProposedViewSize(width: nil, height: nil),
            intrinsicSize: shortIntrinsic,
            inline: true
        ) == CGSize(width: 200, height: 32))
        #expect(NativeCreamSegmentedSizing.measuredSize(
            proposal: ProposedViewSize(width: 306, height: 32),
            intrinsicSize: shortIntrinsic,
            inline: true
        ) == CGSize(width: 200, height: 32))

        let widerIntrinsic = CGSize(width: 224, height: 32)
        #expect(NativeCreamSegmentedSizing.measuredSize(
            proposal: ProposedViewSize(width: nil, height: nil),
            intrinsicSize: widerIntrinsic,
            inline: true
        ) == CGSize(width: 224, height: 32))

        #expect(NativeCreamSegmentedSizing.measuredSize(
            proposal: ProposedViewSize(width: 288, height: 32),
            intrinsicSize: shortIntrinsic,
            inline: false
        ) == CGSize(width: 288, height: 32))
    }

    #if os(iOS)
    @MainActor @Test func nativeCreamSegmentedConfiguresContrastColorsAndHandlesValueSync() {
        let control = UISegmentedControl()
        NativeCreamSegmentedAppearance.configureColors(control)

        #expect(control.selectedSegmentTintColor == UIColor(ShellPalette.cream))
        #expect((control.titleTextAttributes(for: .selected)?[.foregroundColor] as? UIColor) == UIColor.black)
        #expect((control.titleTextAttributes(for: [.selected, .highlighted])?[.foregroundColor] as? UIColor) == UIColor.black)
        #expect((control.titleTextAttributes(for: .normal)?[.foregroundColor] as? UIColor) == UIColor.white)
        #expect((control.titleTextAttributes(for: .highlighted)?[.foregroundColor] as? UIColor) == UIColor.white)

        let options = [SettingOption("handheld", "Handheld"), SettingOption("docked", "Docked")]
        var appliedLabels: [String] = []
        NativeCreamSegmentedAppearance.synchronize(
            control,
            options: options,
            appliedLabels: &appliedLabels,
            value: "handheld",
            isEnabled: true,
            accessibilityLabel: "Play mode",
            accessibilityIdentifier: "setting.DM_OPERATION_MODE",
            animated: false
        )
        #expect(control.numberOfSegments == 2)
        #expect(appliedLabels == ["Handheld", "Docked"])
        #expect(control.selectedSegmentIndex == 0)
        #expect(control.accessibilityLabel == "Play mode")
        #expect(control.accessibilityIdentifier == "setting.DM_OPERATION_MODE")

        // UIKit touch switches the segment first; subsequent synchronize with the new value stays non-destructive.
        var reported: [String] = []
        var current = "handheld"
        control.selectedSegmentIndex = 1
        NativeCreamSegmentedAppearance.handleValueChange(
            control,
            options: options,
            currentValue: &current,
            ignoresPress: { false },
            change: { reported.append($0) }
        )
        #expect(reported == ["docked"])
        #expect(current == "docked")

        NativeCreamSegmentedAppearance.synchronize(
            control,
            options: options,
            appliedLabels: &appliedLabels,
            value: current,
            isEnabled: true,
            accessibilityLabel: "Play mode",
            accessibilityIdentifier: "setting.DM_OPERATION_MODE",
            animated: true
        )
        #expect(control.selectedSegmentIndex == 1)

        // Controller echo guard restores the previous selection without firing `change`.
        control.selectedSegmentIndex = 0
        NativeCreamSegmentedAppearance.handleValueChange(
            control,
            options: options,
            currentValue: &current,
            ignoresPress: { true },
            change: { reported.append($0) }
        )
        #expect(reported == ["docked"])
        #expect(current == "docked")
        #expect(control.selectedSegmentIndex == 1)
    }
    #endif
}
