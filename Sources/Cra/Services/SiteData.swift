import CraCEF
import Foundation

extension CraBrowser {
    /// Arc's "Clear Cookies and Refresh" and "Clear Cache and Refresh": this site's cookies, or
    /// the HTTP cache, then a reload.
    func clearSiteDataAndReload(cookies: Bool) {
        guard let request = SiteDataClearing.request(url: currentURL, cookies: cookies) else { return }
        sendDevToolsMethod(request.method, params: request.params) { [weak self] _, error in
            if let error { NSLog("Cra: clearing site data failed: %@", error) }
            DispatchQueue.main.async { self?.reload() }
        }
    }
}
