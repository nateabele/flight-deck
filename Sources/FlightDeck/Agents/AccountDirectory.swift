import Foundation

/// Reads what a config directory says about itself, and finds directories that look like one.
///
/// Every rule here fails closed: an unreadable or unrecognised home yields nil rather than a
/// guess. Identity is display-only, so a wrong answer must degrade to "no answer", never to a
/// plausible-looking wrong email next to a real account.
enum AccountDirectory {
    /// The file whose presence marks a directory as one of this agent's homes. Asked of the
    /// agent — see `AgentAdapter.homeMarkerFile` — so a third agent states its own rather
    /// than being added to a switch here.
    static func marker(for agent: AgentID) -> String { agent.homeMarkerFile }

    static func looksLikeHome(_ url: URL, agent: AgentID) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(marker(for: agent)).path)
    }

    /// Whether adopting `url` as a home would put an account on top of somebody else's files.
    /// True when there is nothing there to lose: the path does not exist yet, or it is a
    /// directory with no entries.
    ///
    /// This is the other half of the Add/Relocate sanity rule (`AccountDraft.validate`): a home
    /// is acceptable if the agent already lives there (`looksLikeHome`) or if Flight Deck is
    /// effectively creating it. Without it any typed path is accepted, and "Also Delete
    /// Files…" would later offer to move that whole tree to the Trash.
    ///
    /// An existing *empty* directory counts as vacant rather than as a foreign tree — `mkdir`
    /// first and then Add is an ordinary way to do this, the folder panel can create one, and
    /// trashing an empty directory destroys nothing. A path that exists as a file is not
    /// vacant: it is not a directory an agent could ever write a home into.
    static func isVacant(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        else { return true }
        guard isDirectory.boolValue else { return false }
        return (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.isEmpty ?? false
    }

    /// Sibling homes under `directory`, excluding the agent's built-in one — which is seeded
    /// explicitly and must not be discovered twice.
    static func discover(in directory: URL, agent: AgentID) -> [URL] {
        let builtInName = agent.builtInHome.lastPathComponent
        // `.skipsHiddenFiles` hides dot-directories, which is every candidate — enumerate names
        // instead and filter by prefix.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasPrefix(builtInName + "-") }
            .sorted()
            .map { directory.appendingPathComponent($0, isDirectory: true) }
            .filter { looksLikeHome($0, agent: agent) }
    }

    static func identity(atHome home: URL, agent: AgentID) -> AccountIdentity? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent(marker(for: agent)))
        else { return nil }
        return agent.identity(fromHomeData: data)
    }

    /// `<home>/.claude.json` → `oauthAccount.emailAddress` / `organizationName`. Reached
    /// through `ClaudeAdapter.identity(fromHomeData:)`; the parse stays here because the two
    /// parsers are the same job written twice and read best side by side.
    static func claudeIdentity(from data: Data) -> AccountIdentity? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any]
        else { return nil }
        let email = account["emailAddress"] as? String
        let organization = account["organizationName"] as? String
        guard email != nil || organization != nil else { return nil }
        return AccountIdentity(email: email, organization: organization)
    }

    /// `<home>/auth.json` → the `email` claim of `tokens.id_token`.
    ///
    /// The JWT is decoded, never verified: this is a label under a row, not an authorisation
    /// decision, and the only alternative source would be a network call.
    static func codexIdentity(from data: Data) -> AccountIdentity? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let token = tokens["id_token"] as? String
        else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2, let payload = base64URLDecode(String(parts[1])),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return nil }
        guard let email = claims["email"] as? String else { return nil }
        return AccountIdentity(email: email, organization: claims["organization"] as? String)
    }

    /// JWT payloads are base64url with the padding stripped; `Data(base64Encoded:)` accepts
    /// neither difference.
    private static func base64URLDecode(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}
