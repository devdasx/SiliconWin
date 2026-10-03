import SwiftUI
import WebKit

/// Shows Microsoft's official download page. When the user clicks the
/// generated ISO link, SiliconWin takes over the download (so the file goes
/// to the library drive instead of ~/Downloads).
struct MicrosoftDownloadSheet: View {
    let guest: GuestOS
    let onDownload: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Download \(guest.shortName) from Microsoft").font(.headline)
                    Text("Choose the edition and your language, then click the Download button. SiliconWin saves the ISO for you.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            MicrosoftWebView(url: guest.microsoftDownloadPage) { url in
                onDownload(url)
                dismiss()
            }
        }
        .frame(width: 980, height: 760)
    }
}

struct MicrosoftWebView: NSViewRepresentable {
    let url: URL
    let onISO: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onISO: onISO) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        // Microsoft only offers ISO files to browsers that aren't on Windows.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let onISO: (URL) -> Void

        init(onISO: @escaping (URL) -> Void) { self.onISO = onISO }

        private func isInstallerImage(_ url: URL) -> Bool {
            url.path.lowercased().hasSuffix(".iso")
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, isInstallerImage(url) {
                decisionHandler(.cancel)
                onISO(url)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            // Links that open a new window load in place (or start the download).
            if let url = navigationAction.request.url {
                if isInstallerImage(url) { onISO(url) } else { webView.load(navigationAction.request) }
            }
            return nil
        }
    }
}
