# Accessibility review — 6 November 2026

This review records source checks, numerical contrast calculations, and limited simulator evidence. It does not certify the entire app or justify selecting every App Store accessibility label.

## Changes in this pass

- Episode watch/skip actions now have a minimum 44 × 44 point frame with a visible outline. Labels retain their contrast while pressed.
- Personal and shared programme headers, season sections, and episode rows stack at accessibility text sizes. Episode watch status/actions stack at all sizes to avoid crowding on narrow screens.
- Shared-list photo controls and removal-confirmation buttons stack at accessibility sizes; photo-picker labels use text without an icon at those sizes.
- Episode navigation has a minimum 44-point height and hides its decorative chevron from VoiceOver. Shared season expansion exposes its current expanded/collapsed value.
- Earlier fixes in this working tree include stronger secondary text, readable scheduled labels, and horizontally scrolling calendar dates at accessibility sizes.

## Scoped verdicts

| Area | Verdict | Evidence and remaining work |
| --- | --- | --- |
| Dynamic Type, full product | FAIL for unconditional certification | Reviewed text uses scalable styles without a forced size or minimumScaleFactor. Layouts adapt, but compact widgets still truncate long titles and not every screen/state has been exercised. |
| VoiceOver, full product | FAIL for release sign-off | Source has meaningful labels, expansion values, headings, and accessible crop movement/zoom alternatives. Full spoken navigation, focus after updates, modal dismissal, and shared-account flows still need hands-on testing. This is incomplete validation, not a claim that VoiceOver is generally broken. |
| Sufficient Contrast, full product | NEEDS VERIFICATION | Explicit custom theme color pairs below pass 4.5:1. Native secondary labels, destructive/error text, system-theme surfaces, widget appearance/tinting, and Increase Contrast need rendered verification. |
| Touch targets | Source fixes pass; runtime measurement pending | Updated episode buttons enforce 44 × 44 minimums. Screenshot appearance cannot establish effective hit rectangles or successful activation. |
| Reduce Motion | Source check passes | All explicit withAnimation calls in reviewed app views use nil animation when Reduce Motion is enabled. System transitions still need device checks. |
| Voice Control, Switch Control, keyboard | Not verified | Standard controls and named crop actions help, but cannot substitute for navigation and activation checks with each feature enabled. |

## Custom theme contrast calculations

Calculated using WCAG sRGB relative luminance and (lighter + 0.05) / (darker + 0.05). Each row is the minimum over that theme's explicit background, tile, and chart colors. Action surfaces composite 6% accent over the underlying surface; pressed surfaces use 3%, which increases contrast. Disabled controls are excluded. These are source-color calculations, not sampled rendered pixels, and exclude semantic system colors and widgets.

| Theme | Appearance | Secondary text minimum | Action label minimum |
| --- | --- | --- | --- |
+| ocean | Light | 6.50:1 | 5.59:1 |
| ocean | Dark | 6.75:1 | 5.06:1 |
| forest | Light | 6.43:1 | 4.93:1 |
| forest | Dark | 6.73:1 | 5.19:1 |
| sunset | Light | 6.15:1 | 4.63:1 |
| sunset | Dark | 7.14:1 | 5.72:1 |
| lavender | Light | 5.95:1 | 4.79:1 |
| lavender | Dark | 7.40:1 | 4.61:1 |

## Validation and follow-up

- Xcode device build and build-for-testing succeeded after the layout changes. Build logs are in the Xcode action artifacts for this session.
- `git diff --check` passed.
- All 114 regression tests passed after the changes on iPhone 16 / iOS 18.4: 106 Swift Testing tests and 8 XCTest tests, zero failures. Result: `/tmp/WatchMate-accessibility-final-tests.xcresult`; log: `/tmp/WatchMate-accessibility-final-tests.log`. These are regression tests, not automated accessibility audits.
- Final simulator binary visually checked on iPhone 16 / iOS 18.4: episode normal size, episode/show/Up Next at Accessibility XXXL; iPad mini / iOS 18.4: episode at Accessibility XXXL. Visible headers and summary text wrapped without observed overlap or ellipsis. Normal episode status no longer broke “Unwatched” across lines, and Mark watched appeared approximately 44 points tall. Below-fold actions and scrolling were not verified. Screenshots: `/tmp/watchmate-accessibility-final-{episode-normal,episode-ax5,show-ax5,up-next-ax5,ipad-episode-ax5}.png`. Apps were terminated and the iPad simulator shut down after capture.
- iOS 27 device-interaction sessions failed during initialization. The iOS 18.4 simctl fallback can capture screenshots but cannot provide the Xcode tool's accessibility hierarchy or touch interactions. Do not interpret screenshots as a VoiceOver audit.
- Check largest text on search/detail screens, photo crop/removal, settings pickers, shared content with a real test account, and all widget families. Repeat in landscape and narrow iPad windows.
- Use Accessibility Inspector and VoiceOver to verify reading/focus order, complete labels, target bounds, and activation of watch/skip, date selection, season expansion, photo adjustment, and modal controls.
- Check Light/Dark, Increase Contrast, Bold Text, Reduce Motion, Voice Control, Switch Control, and Full Keyboard Access on hardware before making corresponding App Store claims.

Published privacy-policy URL and signed distribution validation remain separate release gates tracked in PRE_RELEASE_REVIEW.md.
