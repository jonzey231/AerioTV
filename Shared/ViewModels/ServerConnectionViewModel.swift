import SwiftUI
import SwiftData

@MainActor
@Observable
final class ServerConnectionViewModel {
    var name: String = ""
    var serverType: ServerType = .dispatcharrAPI
    var baseURL: String = ""      // M3U URL for m3uPlaylist, server base URL for xtreamCodes
    var username: String = ""
    var password: String = ""
    var apiKey: String = ""       // Dispatcharr personal API key
    var epgURL: String = ""       // Optional EPG URL for m3uPlaylist
    var localURL: String = ""     // LAN URL (e.g. http://192.168.1.10:9191)
    var localEPGURL: String = ""  // Local EPG URL for M3U when on LAN

    var isVerifying: Bool = false
    var verificationSuccess: Bool = false
    var verificationError: String? = nil
    var verifiedServerName: String? = nil

    var isFormValid: Bool {
        guard !name.isEmpty, !baseURL.isEmpty else { return false }
        switch serverType {
        case .m3uPlaylist:
            return !baseURL.isEmpty
        case .xtreamCodes:
            return !username.isEmpty && !password.isEmpty
        case .dispatcharrAPI:
            return !apiKey.isEmpty
        }
    }

    func verifyConnection() async {
        guard isFormValid else { return }
        isVerifying = true
        verificationError = nil
        verificationSuccess = false
        verifiedServerName = nil

        do {
            switch serverType {
            case .m3uPlaylist:
                // Verify M3U by fetching and checking for #EXTM3U header
                guard let url = URL(string: baseURL) else { throw APIError.invalidURL }
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw APIError.serverError((response as? HTTPURLResponse)?.statusCode ?? -1)
                }
                guard let content = String(data: data, encoding: .utf8),
                      content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else {
                    throw APIError.decodingError(NSError(domain: "M3U", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "URL does not appear to be a valid M3U playlist"]))
                }
                let channelCount = content.components(separatedBy: "#EXTINF:").count - 1
                verifiedServerName = "\(channelCount) channels found"
                verificationSuccess = true

            case .xtreamCodes:
                let api = XtreamCodesAPI(baseURL: normalizedURL, username: username, password: password)
                let info = try await api.verifyConnection()
                verifiedServerName = info.userInfo.username
                verificationSuccess = true

            case .dispatcharrAPI:
                let api = DispatcharrAPI(baseURL: normalizedURL, auth: .apiKey(apiKey))
                let info = try await api.verifyConnection()
                // Prefer a friendly name if provided; otherwise show version.
                if let name = info.serverName, !name.isEmpty {
                    verifiedServerName = name
                } else {
                    verifiedServerName = "v\(info.version ?? "unknown")"
                }
                verificationSuccess = true
            }
        } catch let error as APIError {
            verificationError = error.errorDescription
        } catch {
            verificationError = error.localizedDescription
        }

        isVerifying = false
    }

    func buildServerConnection() -> ServerConnection {
        ServerConnection(
            name: name,
            type: serverType,
            baseURL: serverType == .m3uPlaylist ? baseURL : normalizedURL,
            username: username,
            password: password,
            apiKey: apiKey,
            epgURL: epgURL,
            localURL: localURL,
            localEPGURL: localEPGURL
        )
    }

    func reset() {
        name = ""
        baseURL = ""
        username = ""
        password = ""
        apiKey = ""
        epgURL = ""
        localURL = ""
        localEPGURL = ""
        isVerifying = false
        verificationSuccess = false
        verificationError = nil
        verifiedServerName = nil
    }

    private var normalizedURL: String {
        var url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.hasSuffix("/") { url = String(url.dropLast()) }
        if !url.hasPrefix("http://") && !url.hasPrefix("https://") {
            url = "http://" + url
        }
        return url
    }
}
