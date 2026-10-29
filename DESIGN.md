# LocalClipboard design contract

Apple-inspired system utility, implemented in Flutter.

## Product hierarchy

The user connects trusted local devices, reads the latest shared text, and sends or copies text. Those tasks determine the layout. No promotional hero, feature strip, repeated privacy slogan, decorative statistics, or illustrated empty state.

Three destinations retain their existing internal IDs: Connections (0, formerly Overview), Clipboard (1), Devices (2). Successful session start/join still opens Clipboard. Background events do not navigate.

## Layout

- Top destination tabs at 900 logical pixels and above; immediate bottom `NavigationBar` selection below 900. Large text moves desktop tabs onto a second header row. Native Windows chrome remains native.
- Content maximum width 1,200; gutters 32 at 1,120 and above, 24 at 900–1,119, and 16 below 900. All destinations share the same alignment.
- Independent destination scroll positions and one retained draft controller. Short windows scroll rather than clipping actions.
- One persistent session toolbar, shown only for a host or selected host; Pause/Resume and session actions remain available across destinations. Desktop hosts expose Add device in the strip; compact layouts expose it in Session actions. Clipboard does not repeat the session summary.
- Connections groups This device with real session members, avoiding a duplicate local-member row. Saved hosts remain separate. Connection setup occupies a narrower area; active sessions disclose existing setup actions under Change connection.
- Split layouts require a window at least 1,120 wide, content at least 1,000 wide, and 15-point text scaling no higher than 20. Main area is flexible; the secondary area is approximately 320 wide with a structural divider. Otherwise stack sections, placing connection actions before long device lists.
- Clipboard places the literal, selectable text beside the labelled composer when split, with sender, actual item status, Copy, and conflict resolution attached to the reading surface. The reading area has no nested inset card. Automatic sharing remains above both areas with its consent flow.
- Devices uses unboxed grouped rows: this device, this session, saved hosts. It shares session-member row presentation with Connections; management actions remain in Devices. Do not infer hardware type from host status.
- Dialogs align to the bottom below 600; desktop dialogs are centred. Content scrolls and action bars use the framework's overflow behavior.

## Colour

Use `_Palette` and explicit `ColorScheme` mappings in `lib/app/ui.dart`, not per-screen colour literals.

| Role | Light | Dark |
| --- | --- | --- |
| Background | `#F5F5F7` | `#101012` |
| Content | `#FFFFFF` | `#1C1C1E` |
| Inset / sidebar | `#F5F5F7` | `#2C2C2E` |
| Text | `#1D1D1F` | `#F5F5F7` |
| Secondary text | `#636366` | `#AEAEB2` |
| Action | `#0066CC` | `#409CFF` |
| Selected fill | `#EDF5FF` | `#142840` |
| Selected label | `#0066CC` | `#80B9FF` |
| Essential outline | `#86868B` | `#8E8E93` |
| Subtle separator | `#E5E5EA` | `#3A3A3C` |
| Success | `#207442` | `#82D39C` |
| Warning | `#855500` | `#F2C66D` |
| Error / error fill | `#BA2428` / `#FFF0F0` | `#FF9A9E` / `#351B1D` |

Blue is an action or selection. State text is authoritative; do not colour-code by parsing `status`, `itemStatus`, or `error`. Receipt codes and typed booleans may control emphasis. Never equate a connection with successful OS clipboard application.

Follow system brightness. Explicit high-contrast themes strengthen separators and group boundaries. Inputs have essential contrasting outlines; keyboard focus changes the outline. Primary-button focus uses its contrasting foreground as an inner boundary. Disabled controls use neutral foregrounds; explanatory text is not faded.

The QR remains dark on white. The scanner's instruction overlay remains white on a dark backing. These are intentional exceptions to surface tokens.

## Type and shape

Use Segoe UI on Windows and the platform default elsewhere; no bundled or network fonts. Apply the family to the final text theme and button text styles so individual style overrides retain it. Native Windows window chrome stays native.

- Destination: 26 / 600, line height 1.2, tracking -0.3.
- Section: 17 / 600; dialog title: 20 / 600.
- Body/editor: 15, line height approximately 1.5; supporting text: 13.
- Controls: 14 / 600, minimum 44-point hit region; navigation labels: 12.
- Pairing figures are tabular and remain one real six-digit input. Displayed codes preserve leading zeros.
- Spacing: 4, 8, 12, 16, 24, 32. Control corners 8; grouped regions 12; dialogs 20.
- Use consistent built-in outline symbols without tinted square badges. No SF Symbols/font redistribution or new icon package.

Text scales with system settings. Fields, warnings, action groups, and code presentation must remain reachable by wrapping or scrolling. Validate large-text output with the supported toolchain before calling it verified.

## Materials

Structural surfaces and private text are opaque. The current source implements the **opaque material fallback**: existing platform adapters do not expose a reliable reduced-transparency preference. Do not add blur that ignores that preference, blur over a uniform sidebar, wallpaper sampling, simulated refraction, glass over glass, or custom shaders merely for appearance.

Layering comes from grouped surfaces, restrained modal elevation, a scrim for modal work, and clear navigation selection. High contrast adds essential boundaries. Real frosted chrome can be a later capability-backed enhancement; it is not silently simulated here.

## Motion

Immediate press colour/focus feedback, with no button-style transition delay. `_SpringPress` adds a critically damped, retargetable presentation effect without owning gesture activation: list rows dim; the main pairing action also scales no lower than approximately 0.985. The underlying framework control retains keyboard/focus/cancel semantics.

`_TaskRoute` uses a critically damped spring from the current route value and velocity. Desktop dialogs use a small scale/opacity transition; narrow tasks use a short lower-edge translation/opacity transition. Dismissal reverses the path, including dismissal during entrance. Focus remains within the modal.

Keyboard interaction uses immediate task presentation through the framework's traditional focus-highlight mode. Navigation selection is immediate for all input modes. No page entrance or device-list stagger is added.

Reduced motion uses immediate presentation. Controllers are disposed and the spring has no idle loop. Shared text is never held in outgoing transition children; payload updates and expiry do not animate. No page-flight, parallax, magnetic cursor effects, confetti, or decorative loops.

## Behavior boundaries

Preserve controller/native boundaries, consent, lifecycle, validation, persistence, request limits, invitation cleanup, clipboard conflict handling, receipt semantics, and the iOS native paste view. UI actions continue to use the existing awaited controller actions and error handling.

Trust removal and clearing shared text use explicit consequence confirmations. Clearing app-held text is not represented as erasing operating-system clipboards/history. Reset retains the original storage-failure eligibility and confirmation flow.

## Verification standard

Run the full required analysis/tests with the project's supported Flutter/Dart SDK. Review all destinations and dialogs at narrow/wide widths, light/dark, large text, reduced motion, high contrast, keyboard navigation, and representative application states. A formatter pass or a partial old-SDK type check does not meet that standard. Native clipboard, network, camera, and tray behavior require separate device verification.
