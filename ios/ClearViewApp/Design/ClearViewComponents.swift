import SwiftUI
import SafariServices

struct CVCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content.padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cvSurfaceContainer, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.cvOutlineVariant.opacity(0.3)))
    }
}

struct CVSectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.title3.bold()).foregroundStyle(Color.cvOnSurface)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(Color.cvOnSurfaceVariant) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CVAvatar: View {
    let name: String
    var url: String? = nil
    var size: CGFloat = 48

    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                Color.cvPrimaryContainer
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.4, weight: .bold)).foregroundStyle(Color.cvPrimary)
            }
        }
        .frame(width: size, height: size).clipShape(Circle()).accessibilityHidden(true)
    }
}

struct CVEmptyState: View {
    let title: String
    let message: String
    var symbol: String = "sparkles"

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 32, weight: .light))
                .foregroundStyle(Color.cvPrimary).frame(width: 76, height: 76)
                .background(Color.cvPrimary.opacity(0.1), in: Circle())
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(Color.cvOnSurfaceVariant)
                .multilineTextAlignment(.center)
        }.padding(30).frame(maxWidth: .infinity)
    }
}

struct CVErrorBanner: View {
    let message: String
    var retry: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark").foregroundStyle(Color.cvPrimary)
            Text(message).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            if let retry { Button("Retry", action: retry).font(.caption.bold()) }
        }.padding(14).background(Color.cvSurfaceContainerHigh, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct CVChip: View {
    let title: String
    var selected = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.medium)).padding(.horizontal, 16).padding(.vertical, 10)
                .foregroundStyle(selected ? Color.cvOnPrimary : Color.cvOnSurfaceVariant)
                .background(selected ? Color.cvPrimary : Color.cvSurfaceContainer, in: Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct BrowserDestination: Identifiable {
    let id = UUID()
    let url: URL

    init?(_ raw: String) {
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        self.url = url
    }
}

struct BrowserSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

extension ApiResult {
    var userMessage: String {
        switch self {
        case .ok: return ""
        case .unreachable: return "Couldn't connect. Check your connection and try again."
        case .failed(let status, let code):
            if status == 401 { return "Your session has expired. Please sign in again." }
            if status == 403 { return "This account doesn't have permission for that action." }
            if status == 429 { return "Too many requests. Please try again in a moment." }
            if code == "auth_unavailable" { return "Account services aren't configured for this build." }
            return "Couldn't complete the request (\(code.replacingOccurrences(of: "_", with: " ")))."
        }
    }
}
