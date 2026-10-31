import SwiftUI

/// Settings tab — how far behind live radio plays, version info and a
/// couple of legal documents shown via QR codes so users can read them on
/// their phone (Apple TV has no browser to open URLs into).
struct SettingsView: View {
    /// How far behind live radio plays (`AppState.seekMode`). The page
    /// shows nothing else of the app's state, so it takes this binding
    /// instead of observing `AppState`: a metadata sync no longer redraws
    /// it under the listener's focus.
    @Binding var seekMode: SeekMode
    /// Toggles playback on the Siri Remote's Play/Pause while a sheet is
    /// up: the tabs' own handler does not reach into a full-screen cover.
    /// The coordinator rather than a closure: the tabs would hand over a
    /// new closure on every render, and SwiftUI then redraws the page.
    let playback: PlaybackCoordinator

    @State private var openLink: LegalLink?
    @State private var showContact = false

    /// A page opened as a QR code.
    private struct LegalLink: Identifiable {
        let id: String
        /// The QR sheet's title: the name of the row that opened it, since
        /// the sheet shows a page, not a station to share.
        let title: String
        let url: URL
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                Text("Setări")
                    .font(.system(size: 56, weight: .heavy))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.bottom, Theme.Spacing.md)

                seekModeSection
                aboutSection
                contactSection
                legalSection
            }
            .padding(.horizontal, Theme.Spacing.xxl)
            .padding(.top, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Modal, like Now Playing. An overlay left the rows and the tab
        // bar in the focus hierarchy: a swipe took focus behind the sheet
        // or switched tabs under it, Menu could then leave the app with
        // the sheet still open, and closing it sent focus to the first
        // row. A cover takes them out while it is up and gives focus back
        // to the row that opened it. The sheets dim the page themselves,
        // so the cover stays see-through.
        .fullScreenCover(item: $openLink) { link in
            ShareSheet(
                heading: link.title,
                url: link.url,
                onDismiss: { openLink = nil }
            )
            .presentationBackground(.clear)
            .onPlayPauseCommand { playback.togglePlayback() }
        }
        .fullScreenCover(isPresented: $showContact) {
            ContactSheet(onDismiss: { showContact = false })
                .presentationBackground(.clear)
                .onPlayPauseCommand { playback.togglePlayback() }
        }
    }

    // MARK: - Sections

    /// "Încărcare în avans", as on the phone: one row per choice, the
    /// chosen one checked. Each row says what the choice does, since the
    /// TV has no room for the phone's toast after a change.
    private var seekModeSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            sectionHeader("Încărcare în avans")
            ForEach(SeekMode.allCases) { mode in
                Button { choose(mode) } label: {
                    seekModeRow(mode, isChosen: mode == seekMode)
                }
                .buttonStyle(.card)
            }
        }
    }

    private var aboutSection: some View {
        section(title: "Despre aplicație", rows: [
            Row(icon: "radio", title: "Radio Crestin",
                subtitle: "Ascultă radiouri creștine din România",
                action: nil),
            Row(icon: "tv", title: "Platformă",
                subtitle: "Apple TV — tvOS",
                action: nil),
            Row(icon: "info.circle", title: "Versiune",
                subtitle: appVersionString,
                action: nil)
        ])
    }

    private var contactSection: some View {
        section(title: "Contact", rows: [
            Row(icon: "message.fill",
                title: "Contactează-ne pe WhatsApp",
                subtitle: "Scanează codul QR cu telefonul pentru a ne scrie",
                action: { openContact() })
        ])
    }

    private var legalSection: some View {
        section(title: "Legal", rows: [
            Row(icon: "doc.text",
                title: "Termeni și condiții",
                subtitle: "Apasă pentru a deschide pe telefon",
                action: { openTerms() }),
            Row(icon: "lock.shield",
                title: "Politica de confidențialitate",
                subtitle: "Apasă pentru a deschide pe telefon",
                action: { openPrivacy() }),
            Row(icon: "globe",
                title: "Site web",
                subtitle: "www.radiocrestin.ro",
                action: { openWebsite() })
        ])
    }

    // MARK: - Row plumbing

    private struct Row: Identifiable {
        /// The title, unique on the page. It must stay the same across
        /// renders: a fresh `UUID()` on each made `ForEach` replace every
        /// row, and the focused one took focus with it to the top of the
        /// page (the page was then redrawn on every metadata sync).
        var id: String { title }
        let icon: String
        let title: String
        let subtitle: String
        let action: (() -> Void)?
    }

    @ViewBuilder
    private func section(title: String, rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            sectionHeader(title)
            ForEach(rows) { row in
                // Every row is a focusable Button so the D-pad can move
                // through the whole page. Informational rows (no
                // `action`) still take focus — they just no-op on
                // select. Without this, focus could only land on the
                // Legal rows and the user couldn't traverse the page.
                Button(action: row.action ?? {}) {
                    rowContent(row)
                }
                .buttonStyle(.card)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 28, weight: .bold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.bottom, Theme.Spacing.xs)
    }

    /// A choice's mark, name and explanation.
    ///
    /// No fill of its own: the `.card` platter behind it is the focus cue,
    /// lighter on the focused row. An opaque fill hid it, so the focused
    /// row differed only by a slight lift.
    private func seekModeRow(_ mode: SeekMode, isChosen: Bool) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 30))
                .foregroundStyle(isChosen ? Theme.primary : Theme.textTertiary)
                .frame(width: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(mode.label)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                SettingsRowSubtitle(text: mode.explanation)
            }
            Spacer()
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A row's icon, title and subtitle, and a chevron when it opens
    /// something. No fill of its own either, as `seekModeRow` explains.
    private func rowContent(_ row: Row) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: row.icon)
                .font(.system(size: 30))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                SettingsRowSubtitle(text: row.subtitle)
            }
            Spacer()
            if row.action != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    private func choose(_ mode: SeekMode) {
        guard mode != seekMode else { return }
        // Same event the iPhone app fires (`SettingsPage.dart`).
        Analytics.capture("button_clicked", properties: [
            "button_name": "buffer_size",
            "seek_mode": mode.rawValue,
            "platform": "apple_tv"
        ])
        seekMode = mode
    }

    private func openContact() {
        // Same event name the iPhone app fires (`SettingsPage.dart`).
        Analytics.capture("whatsapp_contact", properties: ["platform": "apple_tv"])
        showContact = true
    }

    private func openTerms() {
        guard let url = URL(string: "https://www.radiocrestin.ro/terms-of-service/") else { return }
        openLink = LegalLink(id: "terms",
                             title: "Termeni și condiții",
                             url: url)
    }

    private func openPrivacy() {
        guard let url = URL(string: "https://www.radiocrestin.ro/privacy-policy/") else { return }
        openLink = LegalLink(id: "privacy",
                             title: "Politica de confidențialitate",
                             url: url)
    }

    private func openWebsite() {
        guard let url = URL(string: "https://www.radiocrestin.ro") else { return }
        openLink = LegalLink(id: "site",
                             title: "Site web",
                             url: url)
    }

    private var appVersionString: String {
        let bundle = Bundle.main
        let v = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}

/// A Settings row's second line.
///
/// A view of its own so it can read the row's focus: inside a `Button`'s
/// label, `\.isFocused` describes that button. The focused `.card`
/// platter is lighter than the unfocused one, so the line brightens with
/// it to keep its contrast, as on the station cards (see
/// `Theme.cardSubtitleFocused`).
private struct SettingsRowSubtitle: View {
    let text: String

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Text(text)
            .font(.system(size: 20))
            .foregroundStyle(
                isFocused ? Theme.cardSubtitleFocused : Theme.cardSubtitle
            )
    }
}
