import SwiftUI
import ServiceManagement

/// Content of the standalone "DIBar Settings" window.
struct SettingsWindowView: View {
    @Environment(AppState.self) private var appState
    @State private var launchAtLogin: Bool?
    @State private var isUpdatingLaunchAtLogin = false
    @State private var showLogoutConfirmation = false
    @State private var draggedMenuBarComponent: MenuBarComponent?
    @State private var dragOriginMenuBarOrder: [MenuBarComponent]?
    @State private var provisionalMenuBarOrder: [MenuBarComponent]?
    @State private var menuBarDropTargetSlot: Int?
    var onCheckForUpdates: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("DIBar")
                        .font(.system(size: 12, weight: .semibold))
                    Text(Self.versionLine)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Check for updates…") {
                    onCheckForUpdates()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .help("DIBar checks for new versions automatically once a day. Updates are downloaded from GitHub and installed in place.")

            Divider()

            settingsRow("Quality") {
                qualityMenu
            }

            Divider()

            menuBarSection

            Divider()

            settingsRow("Launch at login") {
                if launchAtLogin == nil {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    Toggle("", isOn: launchAtLoginBinding)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .disabled(isUpdatingLaunchAtLogin)
                }
            }

            Divider()

            settingsRow("Play on launch") {
                Toggle("", isOn: Bindable(appState).playOnLaunch)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }
            .help("Automatically play the last channel when DIBar opens. Turning this off does not change Launch at login.")

            Divider()

            settingsRow("Global shortcuts") {
                Toggle("", isOn: Bindable(appState).globalHotkeysEnabled)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }
            .help("System-wide keyboard shortcuts that work in any app.")

            VStack(alignment: .leading, spacing: 5) {
                shortcutRow(label: "play/pause") {
                    KeyCap("⌃"); KeyCap("⌥"); KeyCap("⌘"); KeyCap("P")
                    keySeparator("or")
                    KeyCap(systemImage: "playpause.fill")
                }
                shortcutRow(label: "prev/next fav channel") {
                    KeyCap("⌃"); KeyCap("⌥"); KeyCap("⌘"); KeyCap("←")
                    keySeparator("/")
                    KeyCap("→")
                    keySeparator("or")
                    KeyCap(systemImage: "backward.fill")
                    keySeparator("/")
                    KeyCap(systemImage: "forward.fill")
                }
                shortcutRow(label: "prev/next site") {
                    KeyCap("⌃"); KeyCap("⌥"); KeyCap("⌘"); KeyCap("↑")
                    keySeparator("/")
                    KeyCap("↓")
                }
            }
            .padding(.horizontal, 16)
            // Matches the 10pt a settingsRow leaves below its caption, so the
            // keycaps do not sit tighter against the divider than every other
            // block in the window.
            .padding(.bottom, 10)

            Divider()

            // Grouped: two rows about the same thing. Tightened to 4pt between
            // them and 10pt to the dividers, so proximity now reads as
            // relatedness — stacked settingsRows put 12pt between siblings and
            // only 6pt at the boundary, which said the opposite.
            VStack(spacing: 0) {
                settingsRow("Notification on song change", verticalPadding: 2) {
                    Toggle("", isOn: Bindable(appState).notifyTrackChanges)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                }
                .help("Shows a notification with the artist and song each time the track changes while the popover is closed.")

                settingsRow("Notification on channel switch", verticalPadding: 2) {
                    Toggle("", isOn: Bindable(appState).notifySwitchChanges)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                }
                .help("Shows the site, channel, and song when you switch channels with a keyboard shortcut.")

                if let hint = appState.notifyPermissionHint {
                    notificationPermissionHint(hint)
                        .padding(.top, 4)
                }
            }
            .padding(.vertical, 8)

            Divider()

            settingsRow("Sleep timer quits DIBar") {
                Toggle("", isOn: Bindable(appState).sleepTimerQuitsApp)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }
            .help("When the sleep timer fires, quit DIBar entirely instead of just pausing playback.")

            Divider()

            scrobblingSection

            Divider()

            Button {
                WebBrowserOpener.open(appState.subscriptionURL)
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appState.membershipHeaderLine)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(appState.membershipDetailLine)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            Divider()

            settingsRow("DI.FM account") {
                HStack(spacing: 8) {
                    if let email = appState.accountEmail {
                        Text(email)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    HoverTextButton(title: "Log Out", tint: .red) {
                        showLogoutConfirmation = true
                    }
                }
            }
        }
        .frame(width: 320)
        .task {
            guard launchAtLogin == nil else { return }
            launchAtLogin = await Self.readLaunchAtLoginStatus()
        }
        .alert("Log out of DI.FM?", isPresented: $showLogoutConfirmation) {
            Button("Log Out", role: .destructive) {
                appState.logout()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let email = appState.accountEmail {
                Text("You're signed in as \(email). You'll need to sign in again to listen.")
            } else {
                Text("You'll need to sign in with your account again to listen.")
            }
        }
    }

    // MARK: - Launch at Login

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin ?? false },
            set: updateLaunchAtLogin
        )
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        guard !isUpdatingLaunchAtLogin else { return }
        launchAtLogin = enabled
        isUpdatingLaunchAtLogin = true

        Task {
            let resolved = await Task.detached(priority: .userInitiated) {
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    return enabled
                } catch {
                    return SMAppService.mainApp.status == .enabled
                }
            }.value
            launchAtLogin = resolved
            isUpdatingLaunchAtLogin = false
        }
    }

    private static let appVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"

    /// "1.3.2 · 28 jul 2026" — the date comes from the executable on disk,
    /// so it tracks whatever build is actually running.
    private static let versionLine: String = {
        guard let url = Bundle.main.executableURL,
              let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
                  .flatMap(\.contentModificationDate)
        else { return appVersion }
        return "\(appVersion) · \(date.formatted(date: .abbreviated, time: .omitted))"
    }()

    private static func readLaunchAtLoginStatus() async -> Bool {
        await Task.detached(priority: .userInitiated) {
            SMAppService.mainApp.status == .enabled
        }.value
    }

    // MARK: - Scrobbling

    private var scrobblingSection: some View {
        VStack(spacing: 0) {
            // Last.fm — also feeds Airbuds (connect Last.fm inside Airbuds)
            settingsRow("Last.fm") {
                lastFMControl
            }
            .help("Sends the songs you listen to (at least half through, or 4 minutes) to your Last.fm profile. Apps like Airbuds can read them from there.")

            if let error = appState.scrobbler.connectionError {
                caption(error, color: .orange)
            } else if appState.scrobbler.lastFMNeedsReconnect {
                caption("Last.fm session expired — connect again", color: .orange)
            }
        }
    }

    @ViewBuilder
    private var lastFMControl: some View {
        let scrobbler = appState.scrobbler
        if !LastFMClient.isConfigured {
            Text("Requires an API key (see ScrobbleClients.swift)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        } else if let username = scrobbler.lastFMUsername, scrobbler.lastFMConnected {
            HStack(spacing: 8) {
                Text(username)
                    .font(.system(size: 11))
                HoverTextButton(title: "Disconnect", tint: .red) {
                    scrobbler.disconnectLastFM()
                }
            }
        } else if scrobbler.lastFMPendingToken != nil {
            Button("Finish connecting") {
                scrobbler.finishLastFMConnect()
            }
            .controlSize(.small)
        } else {
            Button("Connect…") {
                scrobbler.connectLastFM()
            }
            .controlSize(.small)
        }
    }

    private func caption(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
    }

    private func notificationPermissionHint(_ hint: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(hint)
            Button("Open System Settings → Notifications") {
                openNotificationSettings()
            }
            .buttonStyle(.plain)
            .underline()
            .cursor(.pointingHand)
        }
        .font(.system(size: 10))
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private func openNotificationSettings() {
        let appURL = TrackNotifier.notificationSettingsURL(bundleIdentifier: Bundle.main.bundleIdentifier)
        if !NSWorkspace.shared.open(appURL) {
            _ = NSWorkspace.shared.open(TrackNotifier.notificationSettingsURL(bundleIdentifier: nil))
        }
    }

    private var qualityMenu: some View {
        Menu {
            ForEach(StreamQuality.allCases) { quality in
                Button {
                    guard appState.selectedQuality != quality else { return }
                    appState.selectedQuality = quality
                    Prefs.set(quality.rawValue, for: .quality)
                    appState.restartStreamForQualityChange()
                } label: {
                    // Every item reserves the checkmark slot so names align
                    let check = Text("\(Image(systemName: "checkmark"))")
                        .foregroundStyle(quality == appState.selectedQuality ? AnyShapeStyle(.primary) : AnyShapeStyle(.clear))
                    Text("\(check) \(quality.displayName)")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(appState.selectedQuality.displayName)
                    .font(.system(size: 11))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .cursor(.pointingHand)
    }

    /// Caption, the simulated menu bar, and the affordance hint. There is only
    /// one representation here on purpose: the user drags and hides the real
    /// values, so there is no schematic that has to be related to a preview.
    private var menuBarSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Menu bar appearance")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            // The anchor sits outside the card because it is not editable. The
            // card holds exactly what the user can rearrange, so its tint is
            // the boundary and no divider is needed.
            HStack(alignment: .center, spacing: Self.menuBarAnchorGap) {
                menuBarAnchor
                    .frame(width: Self.menuBarAnchorWidth, alignment: .leading)
                menuBarCard
            }
            .padding(.top, 8)

            // Indented to the grips rather than the card edge, so the text
            // starts on the same line as the things it describes. Broken by
            // hand, one gesture per line — left to wrap it splits mid-clause.
            Text("Click any to hide\nDrag any to reorder\nRight click to restore defaults")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
                .padding(
                    .leading,
                    Self.menuBarAnchorWidth + Self.menuBarAnchorGap + Self.menuBarCardPadding
                )
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onDisappear(perform: clearMenuBarDrag)
    }

    /// The status item, drawn at 1.25× so its pieces are legible and grabbable.
    /// Metrics track `MenuBarLabelRenderer`'s own constants: 18pt icon → 22,
    /// 8pt symbol gap → 10, 4pt icon gap → 5, 9pt text → 11.
    private var menuBarCard: some View {
        let lines = appState.menuBarSimulationLines(order: displayedMenuBarOrder)
        return VStack(alignment: .leading, spacing: 1) {
            menuBarSimulatedLine(lines.line1, startingAt: 0, weight: .semibold)
            menuBarSimulatedLine(lines.line2, startingAt: 2, weight: .regular)
        }
        .padding(.horizontal, Self.menuBarCardPadding)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        // Backstop: a release on the logo or in the trailing space reaches no
        // slot delegate, which would otherwise strand the provisional order.
        .onDrop(of: [.text], delegate: menuBarDropDelegate(for: Self.menuBarCardDropSlot))
        .contextMenu {
            Button("Restore Default Order") {
                withAnimation(.easeInOut(duration: 0.15)) {
                    clearMenuBarDrag()
                    appState.restoreDefaultMenuBarComponentOrder()
                }
            }
            .disabled(appState.menuBarComponentOrder == MenuBarComponent.defaultOrder)
        }
    }

    /// Glyph 10 + gap 10 + logo 22. Fixed so the hint below can be indented to
    /// the card's leading edge exactly.
    private static let menuBarAnchorWidth: CGFloat = 42
    private static let menuBarAnchorGap: CGFloat = 10
    /// Card inset. 8 not 10: a realistic worst-case line (35 chars plus two
    /// grips) runs ~212pt, and the hover pill already insets itself by 4.
    private static let menuBarCardPadding: CGFloat = 8

    /// The status item's fixed anchor: transport glyph and logo. Neither moves
    /// nor hides, so neither is a control — no hover response, no cursor
    /// change, no grip. It sits outside the card for the same reason.
    private var menuBarAnchor: some View {
        HStack(spacing: 10) {
            // A play triangle regardless of what is actually playing: here it
            // stands for the transport slot, not the current state, and must
            // not change under the user's cursor.
            Image(systemName: "play.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 10)
                .accessibilityLabel("Play state indicator")

            Image("MenuBarIcon")
                .resizable()
                .frame(width: 22, height: 22)
                .foregroundStyle(.primary)
                .accessibilityLabel("DIBar logo")
        }
        .help("The play indicator and the DIBar logo always show — the logo is what you click.")
    }

    /// One line of the label. `startingAt` is the slot index of its first
    /// component — slots 0+1 make line 1, slots 2+3 line 2.
    private func menuBarSimulatedLine(
        _ slots: [MenuBarSlot],
        startingAt firstSlot: Int,
        weight: Font.Weight
    ) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(slots.enumerated()), id: \.element.id) { offset, slot in
                if let separator = slot.separatorBefore {
                    // A separator is only as present as the items it joins, and
                    // it has to fade on the same clock or it snaps mid-crossfade.
                    let joinsVisible = slots[offset - 1].isVisible && slot.isVisible
                    Text(separator)
                        .font(.system(size: 11, weight: weight))
                        .foregroundStyle(.primary)
                        .opacity(joinsVisible ? 1 : 0.35)
                        .animation(MenuBarItemView.hideFade, value: joinsVisible)
                        .fixedSize()
                }
                menuBarSlotItem(slot, in: firstSlot + offset, weight: weight)
            }
        }
    }

    private func menuBarSlotItem(
        _ slot: MenuBarSlot,
        in index: Int,
        weight: Font.Weight
    ) -> some View {
        let component = slot.component
        return MenuBarItemView(
            slot: slot,
            weight: weight,
            isDropTarget: menuBarDropTargetSlot == index,
            isDragActive: draggedMenuBarComponent != nil,
            action: { menuBarVisibilityBinding(for: component).wrappedValue.toggle() }
        )
        .opacity(draggedMenuBarComponent == component ? 0.4 : 1)
        // Hidden slots surrender width first: the 35-character cap governs the
        // visible line only, so two long ghosts can still overflow the card.
        .layoutPriority(slot.isVisible ? 1 : 0)
        .onDrag {
            let order = MenuBarComponent.normalizedOrder(appState.menuBarComponentOrder)
            draggedMenuBarComponent = component
            dragOriginMenuBarOrder = order
            provisionalMenuBarOrder = order
            menuBarDropTargetSlot = nil
            return NSItemProvider(object: component.rawValue as NSString)
        } preview: {
            // At rest an item is bare text, which makes a weak drag image.
            MenuBarItemView(slot: slot, weight: weight, isDropTarget: true, action: {})
        }
        // Identity travels with the component, not the slot, so a swap moves
        // the item rather than recycling the view and cross-fading the words.
        .id(component)
        .onDrop(of: [.text], delegate: menuBarDropDelegate(for: index))
    }

    private var displayedMenuBarOrder: [MenuBarComponent] {
        MenuBarComponent.normalizedOrder(
            provisionalMenuBarOrder ?? appState.menuBarComponentOrder
        )
    }

    /// Outside the 0..<4 slot range, so the card-level delegate never previews a
    /// swap on hover — it only commits whatever the slot delegates staged.
    private static let menuBarCardDropSlot = -1

    private func menuBarDropDelegate(for slot: Int) -> MenuBarComponentDropDelegate {
        MenuBarComponentDropDelegate(
            targetSlot: slot,
            appState: appState,
            draggedComponent: $draggedMenuBarComponent,
            originOrder: $dragOriginMenuBarOrder,
            provisionalOrder: $provisionalMenuBarOrder,
            dropTargetSlot: $menuBarDropTargetSlot
        )
    }

    private func clearMenuBarDrag() {
        draggedMenuBarComponent = nil
        dragOriginMenuBarOrder = nil
        provisionalMenuBarOrder = nil
        menuBarDropTargetSlot = nil
    }

    private func menuBarVisibilityBinding(for component: MenuBarComponent) -> Binding<Bool> {
        switch component {
        case .station:
            Binding(get: { appState.menuBarShowStation }, set: { appState.menuBarShowStation = $0 })
        case .site:
            Binding(get: { appState.menuBarShowSite }, set: { appState.menuBarShowSite = $0 })
        case .artist:
            Binding(get: { appState.menuBarShowArtist }, set: { appState.menuBarShowArtist = $0 })
        case .song:
            Binding(get: { appState.menuBarShowSong }, set: { appState.menuBarShowSong = $0 })
        }
    }

    /// One line of the shortcuts helper: keycaps left, action label right.
    private func shortcutRow(label: String, @ViewBuilder keys: () -> some View) -> some View {
        HStack(spacing: 3) {
            keys()
            Spacer(minLength: 8)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func keySeparator(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
    }

    /// Caption on the left, control flush right, uniform height and padding.
    /// `verticalPadding` drops for rows stacked inside a group, where 6 puts
    /// more space between siblings than the group leaves at its own edges.
    private func settingsRow(
        _ caption: String,
        verticalPadding: CGFloat = 6,
        @ViewBuilder control: () -> some View
    ) -> some View {
        HStack {
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            control()
        }
        .frame(minHeight: 22)
        .padding(.horizontal, 16)
        .padding(.vertical, verticalPadding)
    }
}

private struct MenuBarComponentDropDelegate: DropDelegate {
    let targetSlot: Int
    let appState: AppState
    @Binding var draggedComponent: MenuBarComponent?
    @Binding var originOrder: [MenuBarComponent]?
    @Binding var provisionalOrder: [MenuBarComponent]?
    @Binding var dropTargetSlot: Int?

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            guard let draggedComponent, let originOrder,
                  let sourceSlot = originOrder.firstIndex(of: draggedComponent),
                  originOrder.indices.contains(targetSlot)
            else { return }

            var preview = originOrder
            if sourceSlot != targetSlot {
                preview.swapAt(sourceSlot, targetSlot)
            }
            withAnimation(.easeInOut(duration: 0.15)) {
                provisionalOrder = preview
                dropTargetSlot = sourceSlot == targetSlot ? nil : targetSlot
            }
        }
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated {
            guard dropTargetSlot == targetSlot else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                provisionalOrder = originOrder
                dropTargetSlot = nil
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            if let committedOrder = provisionalOrder ?? originOrder {
                withAnimation(.easeInOut(duration: 0.15)) {
                    appState.menuBarComponentOrder = MenuBarComponent.normalizedOrder(committedOrder)
                }
            }
            draggedComponent = nil
            originOrder = nil
            provisionalOrder = nil
            dropTargetSlot = nil
        }
        return true
    }
}

// MARK: - Key Cap

/// A single keyboard key rendered as a small rounded keycap.
private struct KeyCap: View {
    var label: String?
    var systemImage: String?

    init(_ label: String) { self.label = label }
    init(systemImage: String) { self.systemImage = systemImage }

    var body: some View {
        Group {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 7, weight: .semibold))
            } else {
                Text(label ?? "")
                    .font(.system(size: 9, weight: .medium))
            }
        }
        .foregroundStyle(.secondary)
        .frame(minWidth: 12, minHeight: 11)
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 3.5)
                .fill(.quaternary.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 3.5)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }
}

// MARK: - Simulated Menu Bar Item

/// Chrome shared by every piece of the simulated label. At rest a piece is
/// bare text, exactly as the menu bar draws it; the background appears only
/// under the cursor, so the simulation stays honest until you reach for it.
/// Two columns of dots — the conventional "this object moves" mark. Drawn
/// rather than taken from SF Symbols so the dot size tracks the 11pt text.
private struct DragGrip: View {
    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(spacing: 1.5) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().frame(width: 1.5, height: 1.5)
                    }
                }
            }
        }
        .foregroundStyle(.secondary)
    }
}

private struct MenuBarItemChrome: ViewModifier {
    var isHovered: Bool = false
    var isDropTarget: Bool = false
    /// True while any piece is being dragged, which is when the slots that can
    /// receive it should declare themselves.
    var isDragActive: Bool = false

    func body(content: Content) -> some View {
        content
            // Inflated rather than padded, so the pill can breathe without
            // pushing the simulated label's own metrics around.
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(fill)
                    if isDragActive && !isDropTarget {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    }
                }
                .padding(.horizontal, -4)
                .padding(.vertical, -2)
            }
            .contentShape(Rectangle())
    }

    private var fill: AnyShapeStyle {
        if isDropTarget { return AnyShapeStyle(Color.accentColor.opacity(0.25)) }
        return isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.clear)
    }
}

private extension View {
    func menuBarItemChrome(
        isHovered: Bool = false,
        isDropTarget: Bool = false,
        isDragActive: Bool = false
    ) -> some View {
        modifier(MenuBarItemChrome(
            isHovered: isHovered,
            isDropTarget: isDropTarget,
            isDragActive: isDragActive
        ))
    }
}

/// One draggable piece of the simulated label, showing the real value rather
/// than an abstract name. Hidden pieces stay in place, struck through, so they
/// can be brought back.
private struct MenuBarItemView: View {
    /// Long enough to register as a state change, short enough not to sit
    /// between the click and the result.
    static let hideFade = Animation.easeInOut(duration: 0.22)

    let slot: MenuBarSlot
    let weight: Font.Weight
    var isDropTarget: Bool = false
    var isDragActive: Bool = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                // Always present, not hover-revealed: the whole point is to
                // answer "what moves here?" before anyone reaches for it. It
                // sits outside the item's dimming because it is editor chrome,
                // not part of the label being simulated.
                DragGrip()
                    .foregroundStyle(isHovered ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))

                Text(slot.text)
                    .font(.system(size: 11, weight: weight))
                    .foregroundStyle(.primary)
                    .strikethrough(!slot.isVisible, color: .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .opacity(slot.isVisible ? 1 : 0.35)
                    .animation(Self.hideFade, value: slot.isVisible)
            }
            .menuBarItemChrome(
                isHovered: isHovered,
                isDropTarget: isDropTarget,
                isDragActive: isDragActive
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .cursor(.openHand)
        .accessibilityLabel(
            "\(slot.component.settingsTitle), \(slot.text), \(slot.isVisible ? "shown" : "hidden")"
        )
        .help(
            slot.isVisible
                ? "Click to hide \(slot.component.settingsTitle.lowercased()); drag to reorder"
                : "Click to show \(slot.component.settingsTitle.lowercased()); drag to reorder"
        )
    }
}
