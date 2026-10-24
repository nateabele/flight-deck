import FleetKit
import Foundation

/// Pending server requests are independent of rollout records. The generation in every
/// offer prevents an answer cached on the phone from matching a reused id after reconnect.
@MainActor
final class CodexNativeDialogs {
    struct Pending {
        let id: Any
        let method: String
        let thread: UUID
        let params: [String: Any]
        let open: OpenPrompt
        let decisions: [Any]
    }

    let rpc: CodexRPC
    private let generation = UUID().uuidString.lowercased()
    private(set) var pending: [String: Pending] = [:]
    private var order: [String] = []
    private var parents: [UUID: UUID] = [:]
    private var items: [String: [String: Any]] = [:]
    private var activities: [UUID: SessionActivity] = [:]
    private var submitted: Set<String> = []
    private var observedThreads: Set<UUID> = []
    private var parentRequests: [UUID: Task<Void, Never>] = [:]
    private var itemRequests: [String: Task<Void, Never>] = [:]
    var parentLookup: ((UUID) async -> UUID?)?
    var fileChangeLookup: ((UUID, String) async -> Any?)?
    var onChange: ((UUID, SessionActivity) -> Void)?

    init(rpc: CodexRPC) { self.rpc = rpc }

    func observe(_ thread: UUID) { observedThreads.insert(thread) }
    func unobserve(_ thread: UUID) { observedThreads.remove(thread) }

    func openPrompt(for thread: UUID) -> OpenPrompt? {
        order.compactMap { pending[$0] }.first { root(of: $0.thread) == thread }?.open
    }

    func receive(id: Any, method: String, params: [String: Any]) {
        guard let raw = params["threadId"] as? String, let thread = UUID(uuidString: raw),
              let data = try? JSONSerialization.data(withJSONObject: id, options: [.fragmentsAllowed, .sortedKeys])
        else { return }
        let call = "codex-native:\(generation):\(thread.uuidString.lowercased()):\(data.base64EncodedString())"
        var params = params
        if let item = params["itemId"] as? String, let changes = items[raw.lowercased() + ":" + item]?["changes"] {
            params["fileChanges"] = changes
        }
        let mapped = Self.map(method: method, params: params, call: call)
        pending[call] = Pending(id: id, method: method, thread: thread, params: params,
                                open: mapped.open, decisions: mapped.decisions)
        if !order.contains(call) { order.append(call) }
        onChange?(root(of: thread), .waiting)
        resolveAncestry(thread)
        if method == "item/fileChange/requestApproval", params["fileChanges"] == nil,
           let item = params["itemId"] as? String { recoverFileChanges(call: call, thread: thread, item: item) }
    }

    func notify(_ method: String, params: [String: Any]) {
        if method == "thread/started", let info = params["thread"] as? [String: Any],
           let raw = info["id"] as? String, let child = UUID(uuidString: raw),
           let parentRaw = info["parentThreadId"] as? String, let parent = UUID(uuidString: parentRaw) {
            parents[child] = parent
            return
        }
        if method == "item/started", let thread = params["threadId"] as? String,
           let item = params["item"] as? [String: Any], let id = item["id"] as? String {
            items[thread.lowercased() + ":" + id] = item
            return
        }
        if method == "item/completed", let thread = params["threadId"] as? String,
           let item = params["item"] as? [String: Any], let id = item["id"] as? String {
            items[thread.lowercased() + ":" + id] = nil
        }
        if method == "serverRequest/resolved", let id = params["requestId"],
           let raw = params["threadId"] as? String, let thread = UUID(uuidString: raw) {
            let keys = order.filter { key in
                guard let request = pending[key], request.thread == thread else { return false }
                return Self.sameID(request.id, id)
            }
            for key in keys { pending[key] = nil; submitted.remove(key) }
            order.removeAll { keys.contains($0) }
            publish(thread)
        } else if method == "thread/status/changed", let raw = params["threadId"] as? String,
                  let thread = UUID(uuidString: raw),
                  let activity = CodexThreadStatus.activity(from: params["status"] as? [String: Any]) {
            activities[thread] = activity
            publish(thread)
        } else if method == "turn/completed" || method == "thread/closed" || method == "thread/archived" {
            guard let raw = params["threadId"] as? String, let thread = UUID(uuidString: raw) else { return }
            clear(thread)
            activities[thread] = .idle
            publish(thread)
        }
    }

    func clear(_ thread: UUID) {
        let keys = order.filter { pending[$0]?.thread == thread }
        for key in keys { pending[key] = nil; submitted.remove(key) }
        order.removeAll { keys.contains($0) }
    }

    func disconnected() {
        for task in parentRequests.values { task.cancel() }
        parentRequests.removeAll()
        for task in itemRequests.values { task.cancel() }
        itemRequests.removeAll()
        let threads = Set(pending.values.map(\.thread))
        pending.removeAll()
        order.removeAll()
        submitted.removeAll()
        for thread in threads { onChange?(root(of: thread), .waiting) }
        items.removeAll()
    }

    /// A reconnect can replay a child's approval before its thread/started notification.
    /// Recover ancestry from metadata instead of losing the approval on an unattached child.
    private func resolveAncestry(_ thread: UUID) {
        guard !observedThreads.contains(root(of: thread)), let lookup = parentLookup,
              parentRequests[thread] == nil else { return }
        parentRequests[thread] = Task { [weak self] in
            defer { self?.parentRequests[thread] = nil }
            var current = thread
            var seen: Set<UUID> = []
            while !Task.isCancelled, seen.count < 32, seen.insert(current).inserted {
                guard let parent = await lookup(current), let self else { return }
                self.parents[current] = parent
                if self.observedThreads.contains(parent) { self.publish(thread); return }
                current = parent
            }
        }
    }

    deinit {
        for task in parentRequests.values { task.cancel() }
        for task in itemRequests.values { task.cancel() }
    }

    private func recoverFileChanges(call: String, thread: UUID, item: String) {
        guard let lookup = fileChangeLookup, itemRequests[call] == nil else { return }
        itemRequests[call] = Task { [weak self] in
            defer { self?.itemRequests[call] = nil }
            guard let changes = await lookup(thread, item), let self, let old = self.pending[call] else { return }
            var params = old.params
            params["fileChanges"] = changes
            let mapped = Self.map(method: old.method, params: params, call: call)
            self.pending[call] = Pending(id: old.id, method: old.method, thread: old.thread,
                                         params: params, open: mapped.open, decisions: mapped.decisions)
            self.publish(thread)
        }
    }

    func answer(_ open: OpenPrompt, with answer: PromptAnswer, thread: UUID) -> Bool {
        guard !submitted.contains(open.callID), let request = pending[open.callID], root(of: request.thread) == thread, request.open == open,
              let result = Self.result(for: request, answer: answer) else { return false }
        // Acknowledge locally only as in flight. Keep the offer until the server confirms
        // resolution, so a failed connection never looks like a completed decision.
        submitted.insert(open.callID)
        rpc.respond(to: request.id, result: result)
        return true
    }

    func abort(_ thread: UUID) {
        guard let open = openPrompt(for: thread) else { return }
        _ = answer(open, with: .deny, thread: thread)
    }

    private func root(of thread: UUID) -> UUID {
        var current = thread
        var seen: Set<UUID> = []
        while let parent = parents[current], seen.insert(current).inserted { current = parent }
        return current
    }

    private func publish(_ thread: UUID) {
        let root = root(of: thread)
        onChange?(root, openPrompt(for: root) == nil ? activities[root] ?? .busy : .waiting)
    }

    private static func sameID(_ a: Any, _ b: Any) -> Bool {
        let options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .sortedKeys]
        return (try? JSONSerialization.data(withJSONObject: a, options: options)) ==
            (try? JSONSerialization.data(withJSONObject: b, options: options))
    }

    private static func map(method: String, params: [String: Any], call: String) -> (open: OpenPrompt, decisions: [Any]) {
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            let decisions = params["availableDecisions"] as? [Any] ?? ["accept", "acceptForSession", "decline", "cancel"]
            let options = decisions.map { decision -> PromptQuestion.Option in
                if let text = decision as? String {
                    switch text {
                    case "accept": return .init(label: "Allow once")
                    case "acceptForSession": return .init(label: "Allow for this session")
                    case "decline": return .init(label: "Decline")
                    case "cancel": return .init(label: "Cancel")
                    default: return .init(label: text)
                    }
                }
                if let object = decision as? [String: Any],
                   let wrapper = object["applyNetworkPolicyAmendment"] as? [String: Any],
                   let rule = wrapper["network_policy_amendment"] as? [String: Any],
                   let action = rule["action"] as? String, let host = rule["host"] as? String {
                    return .init(label: action == "allow" ? "Always allow access to \(host)" : "Always deny access to \(host)")
                }
                return .init(label: "Allow and remember this command rule", detail: pretty(decision))
            }
            let network = params["networkApprovalContext"].map(pretty)
            let details = [params["reason"] as? String, network, params["command"] as? String,
                           params["grantRoot"] as? String, params["fileChanges"].map(pretty),
                           params["additionalPermissions"].map(pretty), params["cwd"] as? String].compactMap { $0 }.joined(separator: "\n\n")
            return (.question(callID: call, [.init(question: details.isEmpty ? "Codex is asking for approval" : details,
                options: options,
                unanswerable: method == "item/fileChange/requestApproval" && params["fileChanges"] == nil
                    ? "The change preview is unavailable. Review these edits on your Mac." : nil,
                allowsOther: false)]), decisions)
        case "item/permissions/requestApproval":
            let details = [params["reason"] as? String, params["permissions"].map(pretty)].compactMap { $0 }.joined(separator: "\n\n")
            return (.question(callID: call, [.init(question: details.isEmpty ? "Codex requests additional permissions" : details,
                options: [.init(label: "Grant for this turn"), .init(label: "Grant for this session"), .init(label: "Deny")],
                allowsOther: false)]), [])
        case "item/tool/requestUserInput":
            guard let questions = params["questions"] as? [[String: Any]], !questions.isEmpty else { break }
            let mapped = questions.map { question in
                let options = (question["options"] as? [[String: Any]] ?? []).compactMap { option -> PromptQuestion.Option? in
                    guard let label = option["label"] as? String else { return nil }
                    return .init(label: label, detail: option["description"] as? String)
                }
                return PromptQuestion(header: question["header"] as? String,
                    question: question["question"] as? String ?? "Codex is asking a question", options: options,
                    allowsOther: question["isOther"] as? Bool ?? true,
                    freeTextOnly: options.isEmpty, isSecret: question["isSecret"] as? Bool ?? false)
            }
            return (.question(callID: call, mapped), [])
        case "mcpServer/elicitation/request":
            if params["mode"] as? String == "url", let url = params["url"] as? String {
                return (.question(callID: call, [.init(question: params["message"] as? String ?? "Complete this request in your browser",
                    options: [.init(label: "Completed in browser"), .init(label: "Decline"), .init(label: "Cancel")],
                    allowsOther: false, url: url)]), [])
            }
            if let schema = params["requestedSchema"] as? [String: Any],
               let properties = schema["properties"] as? [String: [String: Any]] {
                if properties.isEmpty {
                    return (.question(callID: call, [.init(question: params["message"] as? String ?? "Confirm this request",
                        options: [.init(label: "Submit"), .init(label: "Decline"), .init(label: "Cancel")], allowsOther: false)]), [])
                }
                let required = Set(schema["required"] as? [String] ?? [])
                let questions = properties.keys.sorted().map { key -> PromptQuestion in
                    let property = properties[key]!
                    let choices = formChoices(property)
                    let multiple = property["type"] as? String == "array"
                    var labels = choices.map { $0.label }
                    if multiple, (property["minItems"] as? Int ?? 0) == 0 { labels.append("None") }
                    if !required.contains(key) { labels.append("Leave blank") }
                    let prompt = [params["message"] as? String, property["description"] as? String].compactMap { $0 }.joined(separator: "\n\n")
                    return .init(header: key, question: prompt.isEmpty ? key : prompt,
                        options: labels.map { .init(label: $0) }, multiSelect: multiple,
                        allowsOther: choices.isEmpty, freeTextOnly: labels.isEmpty,
                        isSecret: property["format"] as? String == "password")
                }
                if !questions.isEmpty { return (.question(callID: call, questions), []) }
            }
        default: break
        }
        return (.question(callID: call, [.init(question: params["message"] as? String ?? "Codex needs your response",
            options: [], unanswerable: "This dialog's controls are not supported yet. Answer it on your Mac.")]), [])
    }

    private static func selections(_ answer: PromptAnswer, questions: [PromptQuestion]) -> [[AnswerSelection]]? {
        let selections: [[AnswerSelection]]
        switch answer {
        case .answers(let value): selections = value
        case .option(let index, let label): selections = [[AnswerSelection(index: index, label: label)]]
        default: return nil
        }
        guard selections.count == questions.count else { return nil }
        for (question, picks) in zip(questions, selections) {
            guard question.isAnswerable, !picks.isEmpty, question.multiSelect || picks.count == 1 else { return nil }
            for pick in picks {
                if let text = pick.text {
                    guard (question.allowsOther || question.freeTextOnly), !text.isEmpty,
                          text.utf8.count <= 65536, pick.index == question.options.count else { return nil }
                } else {
                    guard question.options.indices.contains(pick.index), question.options[pick.index].label == pick.label else { return nil }
                }
            }
        }
        return selections
    }

    private static func result(for request: Pending, answer: PromptAnswer) -> [String: Any]? {
        if answer == .deny {
            switch request.method {
            case "item/commandExecution/requestApproval", "item/fileChange/requestApproval": return ["decision": "cancel"]
            case "item/permissions/requestApproval": return ["permissions": [:]]
            case "item/tool/requestUserInput": return ["answers": [:]]
            case "mcpServer/elicitation/request": return ["action": "decline", "content": NSNull()]
            default: return nil
            }
        }
        guard case .question(_, let questions) = request.open,
              let chosen = selections(answer, questions: questions) else { return nil }
        switch request.method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            let index = chosen[0][0].index
            guard request.decisions.indices.contains(index), chosen[0][0].text == nil else { return nil }
            return ["decision": request.decisions[index]]
        case "item/permissions/requestApproval":
            let index = chosen[0][0].index
            if index == 2 { return ["permissions": [:]] }
            guard index == 0 || index == 1, let permissions = request.params["permissions"] as? [String: Any] else { return nil }
            return ["permissions": permissions, "scope": index == 0 ? "turn" : "session"]
        case "item/tool/requestUserInput":
            guard let originals = request.params["questions"] as? [[String: Any]] else { return nil }
            var answers: [String: Any] = [:]
            for (question, picks) in zip(originals, chosen) {
                guard let id = question["id"] as? String else { return nil }
                answers[id] = ["answers": picks.map { $0.text ?? $0.label }]
            }
            return ["answers": answers]
        case "mcpServer/elicitation/request":
            if request.params["mode"] as? String == "url" {
                return ["action": ["accept", "decline", "cancel"][chosen[0][0].index], "content": NSNull()]
            }
            guard let schema = request.params["requestedSchema"] as? [String: Any],
                  let properties = schema["properties"] as? [String: [String: Any]] else { return nil }
            if properties.isEmpty {
                let action = ["accept", "decline", "cancel"][chosen[0][0].index]
                return ["action": action, "content": action == "accept" ? [:] as [String: Any] : NSNull()]
            }
            var content: [String: Any] = [:]
            for (key, picks) in zip(properties.keys.sorted(), chosen) {
                guard let property = properties[key] else { return nil }
                let choices = formChoices(property)
                let isArray = property["type"] as? String == "array"
                let required = (schema["required"] as? [String] ?? []).contains(key)
                let noneIndex = isArray && (property["minItems"] as? Int ?? 0) == 0 ? choices.count : nil
                let skipIndex = choices.count + (noneIndex == nil ? 0 : 1)
                if !required, picks.count == 1, picks[0].text == nil, picks[0].index == skipIndex { continue }
                if isArray, !choices.isEmpty {
                    if let noneIndex, picks.count == 1, picks[0].text == nil, picks[0].index == noneIndex {
                        content[key] = [Any]()
                        continue
                    }
                    guard Set(picks.map(\.index)).count == picks.count,
                          picks.allSatisfy({ $0.text == nil && choices.indices.contains($0.index) }),
                          picks.count >= (property["minItems"] as? Int ?? 0),
                          picks.count <= (property["maxItems"] as? Int ?? Int.max) else { return nil }
                    content[key] = picks.map { choices[$0.index].value }
                } else if picks.count == 1, picks[0].text == nil, choices.indices.contains(picks[0].index) {
                    content[key] = choices[picks[0].index].value
                } else {
                    guard picks.count == 1, let text = picks[0].text,
                          let value = formValue(text, schema: property) else { return nil }
                    content[key] = value
                }
            }
            return ["action": "accept", "content": content]
        default: return nil
        }
    }

    private static func formChoices(_ schema: [String: Any]) -> [(label: String, value: Any)] {
        if schema["type"] as? String == "boolean" { return [("true", true), ("false", false)] }
        let node = schema["type"] as? String == "array" ? schema["items"] as? [String: Any] ?? [:] : schema
        if let values = node["enum"] as? [Any] {
            let names = node["enumNames"] as? [String] ?? []
            return values.enumerated().map { (names.indices.contains($0.offset) ? names[$0.offset] : String(describing: $0.element), $0.element) }
        }
        let values = node["oneOf"] as? [[String: Any]] ?? node["anyOf"] as? [[String: Any]] ?? []
        return values.compactMap { option in
            guard let value = option["const"] else { return nil }
            return (option["title"] as? String ?? String(describing: value), value)
        }
    }

    private static func formValue(_ text: String, schema: [String: Any]) -> Any? {
        if let choices = schema["enum"] as? [Any] {
            return choices.first { String(describing: $0) == text }
        }
        switch schema["type"] as? String {
        case "boolean": return text == "true" ? true : text == "false" ? false : nil
        case "number", "integer":
            guard let number = Double(text), number.isFinite else { return nil }
            if schema["type"] as? String == "integer", number.rounded() != number { return nil }
            if let min = schema["minimum"] as? NSNumber, number < min.doubleValue { return nil }
            if let max = schema["maximum"] as? NSNumber, number > max.doubleValue { return nil }
            return number
        case "string":
            if let min = schema["minLength"] as? Int, text.unicodeScalars.count < min { return nil }
            if let max = schema["maxLength"] as? Int, text.unicodeScalars.count > max { return nil }
            return text
        case "array", "object":
            guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return nil }
            if schema["type"] as? String == "array" { return value as? [Any] }
            return value as? [String: Any]
        default: return nil
        }
    }

    private static func pretty(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

struct CodexPromptResponder: AgentPromptResponder {
    func answer(_ open: OpenPrompt, with answer: PromptAnswer, for target: AgentTarget) -> Bool {
        guard let adapter = target.adapter as? CodexAdapter else { return false }
        return adapter.nativeDialogs?.answer(open, with: answer, thread: target.location.binding.conversationID) ?? false
    }

    func abort(for target: AgentTarget) {
        guard let adapter = target.adapter as? CodexAdapter else { return }
        adapter.nativeDialogs?.abort(target.location.binding.conversationID)
    }
}
