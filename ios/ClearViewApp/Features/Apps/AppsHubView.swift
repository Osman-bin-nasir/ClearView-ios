import SwiftUI

struct AppsHubView: View {
    @State private var library = AppsLibrary()
    @State private var selectedApp: AppSite?
    @State private var showSettings = false
    @State private var showShortcut = false
    @State private var address = ""

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("ClearView").font(.system(size: 45, weight: .light)).tracking(-1.8)
                                    .foregroundStyle(Color.cvOnSurface)
                                Text("A calmer way to browse").font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.cvOnSurfaceVariant)
                            }
                            Spacer(minLength: 8)
                            Button { showSettings = true } label: {
                                Image(systemName: "gearshape.fill").font(.system(size: 21))
                                    .foregroundStyle(Color.cvOnSurfaceVariant).frame(width: 44, height: 50)
                            }.accessibilityLabel("Protection settings").accessibilityIdentifier("apps.protection-settings")
                        }
                        VStack(alignment: .leading, spacing: 22) {
                            Text("Apps").font(.subheadline.weight(.medium))
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .background(Color.cvSurfaceContainerLow, in: Capsule())
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), alignment: .leading, spacing: 24) {
                                ForEach([AppSite.google, .youtube, .instagram, .snapchat, .facebook]) { site in
                                    shortcut(name: site.name) { AppBrandMark(site: site, size: 56) } action: { selectedApp = site }
                                        .accessibilityLabel("Open \(site.name)")
                                }
                                ForEach(library.shortcuts) { item in
                                    shortcut(name: item.name) {
                                        BrowserShortcutIcon(shortcut: item)
                                    } action: { open(item.url) }
                                    .accessibilityLabel(item.name)
                                    .contextMenu {
                                        Button("Remove shortcut", systemImage: "trash", role: .destructive) { library.removeShortcut(item.id) }
                                    }
                                }
                                shortcut(name: "Add shortcut") {
                                    Image(systemName: "plus").font(.system(size: 25, weight: .medium)).foregroundStyle(Color.cvPrimary)
                                        .frame(width: 56, height: 56).background(Color.cvSurfaceContainerHigh, in: Circle())
                                } action: { showShortcut = true }
                            }
                        }
                        Spacer(minLength: 24)
                    }.padding(.horizontal, 26).padding(.top, 26)
                        .frame(minHeight: geometry.size.height, alignment: .top)
                }.scrollDismissesKeyboard(.interactively)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { webSearch.padding(.horizontal, 26).padding(.vertical, 18).background(Color.cvBackground) }
            .background(Color.cvBackground).toolbar(.hidden, for: .navigationBar)
            .fullScreenCover(item: $selectedApp) { site in
                AppBrowserView(session: library.session(for: site), library: library)
            }
            .sheet(isPresented: $showSettings) { BrowserProtectionSettingsView(library: library) }
            .sheet(isPresented: $showShortcut) { AddBrowserShortcutView(library: library) }
        }
    }

    private var webSearch: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.cvOnSurfaceVariant)
            TextField("Search the web", text: $address).font(.subheadline.weight(.semibold))
                .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.go).onSubmit(submit)
                .accessibilityIdentifier("apps.web-search")
            Button(action: submit) { Image(systemName: "arrow.right").font(.system(size: 20)).frame(width: 32, height: 38) }
                .accessibilityLabel("Search or open website").disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 6)
            .foregroundStyle(Color.cvOnSurface).background(Color.cvBackground, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.cvOutline.opacity(0.8), lineWidth: 1.5))
    }

    private func shortcut<Icon: View>(name: String, @ViewBuilder icon: () -> Icon, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 9) {
                icon()
                Text(name).font(.system(size: 11, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
                    .foregroundStyle(Color.cvOnSurfaceVariant)
            }.frame(maxWidth: .infinity, minHeight: 83, alignment: .top).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func submit() {
        guard let url = AppsLibrary.browserURL(address) else { return }
        open(url)
        address = ""
    }
    private func open(_ url: URL) {
        library.session(for: .web).open(url)
        selectedApp = .web
    }
}

struct AppBrandMark: View {
    let site: AppSite
    var size: CGFloat = 40
    var body: some View {
        ZStack {
            Circle().fill(background)
            switch site {
            case .google, .web:
                Text("G").font(.system(size: size * 0.59, weight: .bold, design: .rounded))
                    .foregroundStyle(AngularGradient(colors: [.blue, .green, .yellow, .red, .blue], center: .center))
            case .youtube:
                Image(systemName: "play.rectangle.fill").font(.system(size: size * 0.52)).foregroundStyle(.red)
            case .instagram:
                Image(systemName: "camera").font(.system(size: size * 0.51, weight: .medium))
                    .foregroundStyle(LinearGradient(colors: [.purple, .pink, .orange], startPoint: .topTrailing, endPoint: .bottomLeading))
            case .snapchat:
                SnapchatGhostMark(eyeColor: background)
                    .frame(width: size * 0.5, height: size * 0.56)
            case .facebook:
                Text("f").font(.system(size: size * 0.68, weight: .bold, design: .rounded))
                    .foregroundStyle(.white).offset(y: -size * 0.02)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }

    private var background: Color {
        switch site {
        case .snapchat: return Color(red: 1, green: 0.99, blue: 0)
        case .facebook: return Color(red: 0.094, green: 0.467, blue: 0.949)
        default: return .white
        }
    }
}

/// Snapchat's ghost, drawn rather than borrowed: SF Symbols has no ghost glyph, and the
/// launcher gives every app its own brand mark instead of a generic icon.
private struct SnapchatGhostMark: View {
    let eyeColor: Color

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: width * 0.5, y: 0))
                    path.addCurve(
                        to: CGPoint(x: width, y: height * 0.44),
                        control1: CGPoint(x: width * 0.78, y: 0),
                        control2: CGPoint(x: width, y: height * 0.18)
                    )
                    path.addLine(to: CGPoint(x: width, y: height * 0.78))
                    path.addQuadCurve(to: CGPoint(x: width * 0.72, y: height * 0.78),
                                      control: CGPoint(x: width * 0.86, y: height))
                    path.addQuadCurve(to: CGPoint(x: width * 0.5, y: height * 0.78),
                                      control: CGPoint(x: width * 0.61, y: height))
                    path.addQuadCurve(to: CGPoint(x: width * 0.28, y: height * 0.78),
                                      control: CGPoint(x: width * 0.39, y: height))
                    path.addQuadCurve(to: CGPoint(x: 0, y: height * 0.78),
                                      control: CGPoint(x: width * 0.14, y: height))
                    path.addLine(to: CGPoint(x: 0, y: height * 0.44))
                    path.addCurve(
                        to: CGPoint(x: width * 0.5, y: 0),
                        control1: CGPoint(x: 0, y: height * 0.18),
                        control2: CGPoint(x: width * 0.22, y: 0)
                    )
                    path.closeSubpath()
                }.fill(.black)
                HStack(spacing: width * 0.16) {
                    Capsule().frame(width: width * 0.12, height: height * 0.16)
                    Capsule().frame(width: width * 0.12, height: height * 0.16)
                }.foregroundStyle(eyeColor).offset(y: height * 0.34)
            }
        }
    }
}

private struct AddBrowserShortcutView: View {
    let library: AppsLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    private var url: URL? {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value.contains("://") ? value : "https://" + value),
              url.scheme == "https", let host = url.host, host.contains("."), !host.contains(" ") else { return nil }
        return url
    }
    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name).textInputAutocapitalization(.words)
                TextField("Website address", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Text("Your browser protection applies to this shortcut too.").font(.footnote).foregroundStyle(Color.cvOnSurfaceVariant)
            }.scrollContentBackground(.hidden).background(Color.cvBackground)
                .navigationTitle("Add shortcut").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") {
                            if let url { library.addShortcut(name: String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32)), url: url); dismiss() }
                        }.disabled(url == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || library.shortcuts.count >= 24)
                    }
                }
        }.tint(.cvPrimary).presentationDetents([.medium])
    }
}
