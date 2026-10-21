import SwiftUI

struct AppsHubView: View {
    @State private var library = AppsLibrary()
    @State private var selectedApp: AppSite?
    @State private var settingsApp: AppSite?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    introduction
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("YOUR APPS").font(.caption.weight(.semibold)).tracking(1.5)
                            Spacer()
                            Text("2 apps").font(.caption)
                        }.foregroundStyle(Color.cvOnSurfaceVariant)
                        ForEach(AppSite.allCases) { site in
                            launchCard(site)
                        }
                    }
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "lock.shield").foregroundStyle(Color.cvPrimary).font(.title3)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Your account stays yours").font(.subheadline.weight(.semibold))
                            Text("Sign in on each app’s own website. Saved sessions stay on this device, ready for your next visit.")
                                .font(.footnote).foregroundStyle(Color.cvOnSurfaceVariant)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.cvSurfaceContainerLow, in: RoundedRectangle(cornerRadius: 20))
                }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 20)
            }
            .background(Color.cvBackground)
            .navigationTitle("Apps")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color.cvBackground, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(AppSite.allCases) { site in
                            Button("\(site.name) filters", systemImage: "slider.horizontal.3") { settingsApp = site }
                        }
                    } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("App filters")
                }
            }
            .fullScreenCover(item: $selectedApp) { site in
                AppBrowserView(session: library.session(for: site), library: library)
            }
            .sheet(item: $settingsApp) { site in
                AppFilterSettingsView(site: site, library: library)
            }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("ON YOUR TERMS", systemImage: "sparkle")
                .font(.caption2.weight(.bold)).tracking(1.8).foregroundStyle(Color.cvPrimary)
            Text("The apps you love.\nA little less noise.")
                .font(.system(size: 29, weight: .bold, design: .rounded)).tracking(-0.6)
                .foregroundStyle(Color.cvOnSurface).fixedSize(horizontal: false, vertical: true)
            Text("Your real feeds, messages and subscriptions, with room for what matters to you.")
                .font(.subheadline).foregroundStyle(Color.cvOnSurfaceVariant).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Label("Keyword filters built in", systemImage: "checkmark.shield.fill")
                .font(.caption.weight(.medium)).foregroundStyle(Color.cvOnPrimaryContainer)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.cvPrimaryContainer, in: Capsule())
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 26).fill(
                    LinearGradient(colors: [Color.cvPrimary.opacity(0.13), Color.cvSurfaceContainerLow],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(Color.cvPrimary.opacity(0.12), lineWidth: 1))
    }

    private func launchCard(_ site: AppSite) -> some View {
        let prefs = library.preferences(for: site)
        let blocksShortVideos = library.blocksShortVideos(for: site)
        return VStack(spacing: 0) {
            Button { selectedApp = site } label: {
                HStack(spacing: 16) {
                    AppBrandMark(site: site, size: 56)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(site.name).font(.title3.weight(.bold)).foregroundStyle(Color.cvOnSurface)
                        Text(site.subtitle).font(.footnote).foregroundStyle(Color.cvOnSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.up.right").font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.cvPrimary)
                }.padding(20).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Open \(site.name)")
            Rectangle().fill(Color.cvOutlineVariant.opacity(0.45)).frame(height: 0.5).padding(.horizontal, 20)
            Button { settingsApp = site } label: {
                HStack(spacing: 7) {
                    Image(systemName: blocksShortVideos ? "eye.slash" : "line.3.horizontal.decrease")
                        .foregroundStyle(Color.cvPrimary)
                    Text(blocksShortVideos ? "\(site.shortVideoName) hidden" : "\(site.shortVideoName) allowed")
                    Text("·").foregroundStyle(Color.cvOutline)
                    Text(prefs.keywords.isEmpty ? "Add keywords" : "\(prefs.keywords.count) keywords")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                }.font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                    .padding(.horizontal, 20).padding(.vertical, 14).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(site.name) filters")
        }.background(Color.cvSurfaceContainerLow, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Color.cvOutlineVariant.opacity(0.3), lineWidth: 0.5))
    }
}

struct AppBrandMark: View {
    let site: AppSite
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28).fill(
                LinearGradient(colors: site == .youtube
                    ? [Color(red: 1, green: 0.23, blue: 0.27), Color(red: 0.8, green: 0.06, blue: 0.12)]
                    : [Color(red: 0.56, green: 0.27, blue: 0.89), Color(red: 0.91, green: 0.25, blue: 0.49), Color(red: 1, green: 0.67, blue: 0.28)],
                    startPoint: .topTrailing, endPoint: .bottomLeading))
            Image(systemName: site == .youtube ? "play.rectangle.fill" : "camera")
                .font(.system(size: size * 0.52, weight: .semibold)).foregroundStyle(.white)
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}
