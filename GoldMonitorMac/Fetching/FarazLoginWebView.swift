import SwiftUI
import WebKit

/// In-app browser for logging into Faraz and capturing the resulting
/// session cookie. Presented by the app root when `FarazAuthCoordinator`
/// reports a 401. Works on macOS (NSViewRepresentable) and iPad/iPhone
/// (UIViewRepresentable) off the same controller.
///
/// Cookie capture: the WKWebView uses the persistent default data store;
/// after the user logs in we read every `faraz`-domain cookie from
/// `httpCookieStore` and join them into a `name=value; …` header string —
/// exactly the shape `FarazHistorySource` sends on the `Cookie` header.

// MARK: - Controller

@MainActor
final class FarazWebController: ObservableObject {
    fileprivate weak var webView: WKWebView?

    @Published var currentURL: String = ""
    @Published var isLoading: Bool = false
    @Published var canGoBack: Bool = false
    /// Count of faraz-domain cookies currently in the store — used to
    /// enable the "Use this session" button once a login has set some.
    @Published var farazCookieCount: Int = 0

    fileprivate func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    func goBack() { webView?.goBack() }
    func reload() { webView?.reload() }

    /// Read the current faraz-domain cookies and hand back a `Cookie`
    /// header string. Empty if the store has none.
    func captureCookieHeader(_ completion: @escaping (String) -> Void) {
        guard let store = webView?.configuration.websiteDataStore.httpCookieStore else {
            completion("")
            return
        }
        store.getAllCookies { cookies in
            let header = Self.header(from: cookies)
            completion(header)
        }
    }

    /// Refresh `farazCookieCount` + navigation state after a page loads.
    func refreshState() {
        canGoBack = webView?.canGoBack ?? false
        currentURL = webView?.url?.absoluteString ?? currentURL
        guard let store = webView?.configuration.websiteDataStore.httpCookieStore else { return }
        store.getAllCookies { [weak self] cookies in
            self?.farazCookieCount = cookies.filter { Self.isFaraz($0) }.count
        }
    }

    private static func isFaraz(_ c: HTTPCookie) -> Bool {
        c.domain.lowercased().contains("faraz")
    }

    private static func header(from cookies: [HTTPCookie]) -> String {
        cookies
            .filter { isFaraz($0) }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }
}

// MARK: - Navigation delegate (shared)

final class FarazWebCoordinator: NSObject, WKNavigationDelegate {
    private let controller: FarazWebController
    init(_ controller: FarazWebController) { self.controller = controller }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in controller.isLoading = true }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            controller.isLoading = false
            controller.refreshState()
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in controller.isLoading = false }
    }
}

// MARK: - Representable

struct FarazWebViewRepresentable {
    let url: URL
    let controller: FarazWebController

    @MainActor
    fileprivate func makeWebView(_ coordinator: FarazWebCoordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = coordinator
        controller.attach(webView)
        webView.load(URLRequest(url: url))
        return webView
    }
}

#if os(macOS)
extension FarazWebViewRepresentable: NSViewRepresentable {
    func makeCoordinator() -> FarazWebCoordinator { FarazWebCoordinator(controller) }
    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#elseif os(iOS)
extension FarazWebViewRepresentable: UIViewRepresentable {
    func makeCoordinator() -> FarazWebCoordinator { FarazWebCoordinator(controller) }
    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

// MARK: - Sheet

/// The full login sheet: a slim header (reason + capture button) over the
/// embedded web view. Same layout on macOS and iOS.
struct FarazLoginSheet: View {
    var reason: String?
    var onCapture: (String) -> Void
    var onCancel: () -> Void

    @StateObject private var controller = FarazWebController()

    private var startURL: URL {
        URL(string: DataSourceConfig.shared.farazAPIURL) ?? URL(string: "https://faraz.io")!
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.Color.border)
            FarazWebViewRepresentable(url: startURL, controller: controller)
        }
        .background(Theme.Color.canvas)
        #if os(macOS)
        // macOS/iPad form-sheets need an explicit size; iPhone sheets fill
        // the screen on their own, so don't force a width wider than it.
        .frame(minWidth: 520, minHeight: 640)
        #endif
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Color.textSecondary)

                Spacer()

                VStack(spacing: 2) {
                    Text("Log in to Faraz")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.Color.textPrimary)
                    if let reason {
                        Text(reason)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Color.textMuted)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Button {
                    controller.captureCookieHeader { header in
                        if !header.isEmpty { onCapture(header) }
                    }
                } label: {
                    Text("Use this session")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(
                                controller.farazCookieCount > 0
                                    ? AnyShapeStyle(Theme.accentGradient)
                                    : AnyShapeStyle(Theme.Color.surfaceMax)
                            )
                        )
                }
                .buttonStyle(.plain)
                .disabled(controller.farazCookieCount == 0)
            }

            // Navigation strip: back / reload / current URL / progress.
            HStack(spacing: 10) {
                Button { controller.goBack() } label: {
                    Image(systemName: "chevron.left")
                        .foregroundStyle(controller.canGoBack ? Theme.Color.textSecondary : Theme.Color.textMuted)
                }
                .buttonStyle(.plain)
                .disabled(!controller.canGoBack)

                Button { controller.reload() } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(Theme.Color.textSecondary)
                }
                .buttonStyle(.plain)

                Text(controller.currentURL.isEmpty ? startURL.absoluteString : controller.currentURL)
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(Theme.Color.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                if controller.isLoading {
                    ProgressView().controlSize(.small)
                } else if controller.farazCookieCount > 0 {
                    Label("\(controller.farazCookieCount)", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Color.success)
                }
            }
            .font(.system(size: 13))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.Color.surface)
    }
}
