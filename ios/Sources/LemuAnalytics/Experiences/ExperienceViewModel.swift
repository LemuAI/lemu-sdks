import Foundation

/// The answer to a submit: the HTTP status (nil when the request failed) and the JSON body.
struct ExperienceSubmitResult {
    var status: Int?
    var json: JSONObject?
}

/// What a view model asks of the manager. Called on the main thread.
protocol ExperienceViewModelHost: AnyObject {
    func viewModel(_ model: ExperienceViewModel, closedByUser byUser: Bool)
    func viewModel(_ model: ExperienceViewModel, clicked target: String)
    func viewModel(_ model: ExperienceViewModel, open url: URL)
    func viewModel(_ model: ExperienceViewModel, submitted fields: JSONObject, offer: JSONObject?)
    func viewModel(
        _ model: ExperienceViewModel,
        send fields: JSONObject,
        otp: String?,
        phoneCountry: String,
        completion: @escaping (ExperienceSubmitResult) -> Void
    )
}

/// One experience on screen: its steps, the answers so far, validation,
/// submitting and the offer. Platform-free; the UIKit view renders it and
/// forwards taps and typing. Used on the main thread only.
final class ExperienceViewModel {
    static let otpField = "_otp"

    enum Message {
        static let required = "Please fill in the highlighted fields."
        static let email = "Enter a valid email address."
        static let phone = "Enter a valid phone number."
        static let tooMany = "Please try again in a minute."
        static let failed = "Something went wrong. Please try again."
        static let offline = "Couldn't send. Check your connection and try again."
        static let otpLabel = "Enter the code we sent on WhatsApp"
    }

    let experience: Experience
    let variant: ExperienceVariant
    let theme: ExperienceTheme
    let steps: [ExperienceStep]
    weak var host: ExperienceViewModelHost?

    private(set) var stepIndex = 0
    private(set) var answers: JSONObject = [:]
    private(set) var offer: JSONObject?
    private(set) var error: String?
    private(set) var invalid: Set<String> = []
    private(set) var busy = false
    private(set) var otpPending = false
    private(set) var copied = false
    private(set) var isClosed = false
    private var otp = ""

    /// The view re-renders when this is called (step, error, busy or offer changed).
    var onChange: (() -> Void)?
    /// The view removes itself when this is called.
    var onDismiss: (() -> Void)?

    init(experience: Experience, variant: ExperienceVariant, theme: ExperienceTheme) {
        self.experience = experience
        self.variant = variant
        self.theme = theme
        steps = variant.steps
        enterStep()
    }

    var format: String { return experience.format }
    var layout: JSONObject { return variant.layout }
    var showsCloseButton: Bool { return jsonBool(layout["close_button"]) != false }
    var dimsBackground: Bool { return format == "popup" && jsonBool(layout["overlay"]) != false }
    var closesOnOverlayTap: Bool { return jsonBool(layout["close_on_overlay"]) != false }

    /// Seconds before a toast hides itself; 0 means never. Other formats stay.
    var autoHideSeconds: Double {
        guard format == "toast" else { return 0 }
        return max(0, jsonNumber(layout["auto_hide_seconds"]) ?? 8)
    }

    var currentStep: ExperienceStep? {
        return stepIndex < steps.count ? steps[stepIndex] : nil
    }

    /// The current step's blocks the app can render. While a code is being
    /// verified, the fields give way to one code input.
    var blocks: [JSONObject] {
        guard let step = currentStep else { return [] }
        let supported: Set<String> = ["heading", "text", "image", "button", "field", "offer", "close"]
        var out = step.blocks.filter { supported.contains(jsonString($0["type"]) ?? "") }
        out = out.filter { jsonString($0["type"]) != "field" || jsonString($0["input"]) != "hidden" }
        if !hasOffer { out = out.filter { jsonString($0["type"]) != "offer" } }
        if otpPending {
            out = out.filter { jsonString($0["type"]) != "field" }
            let code: JSONObject = [
                "type": "field", "input": "otp", "name": ExperienceViewModel.otpField,
                "label": Message.otpLabel, "required": true,
            ]
            let at = out.firstIndex(where: { jsonString($0["type"]) == "button" }) ?? out.count
            out.insert(code, at: at)
        }
        return out
    }

    var hasOffer: Bool {
        guard let o = offer else { return false }
        return !(jsonString(o["code"]) ?? "").isEmpty || !(jsonString(o["headline"]) ?? "").isEmpty
    }

    var offerCode: String? {
        guard let code = jsonString(offer?["code"]), !code.isEmpty else { return nil }
        return code
    }

    // MARK: Text

    /// A block's text with placeholders filled and markdown markers removed.
    func text(_ value: Any?) -> String {
        guard let raw = value, !(raw is NSNull) else { return "" }
        let filled = ExperienceRules.fill(ExperienceRules.text(raw), scopes: ["answers": answers, "offer": offer ?? [:]])
        return ExperienceRules.plainText(filled)
    }

    func buttonTitle(_ block: JSONObject) -> String {
        let t = text(block["text"])
        return t.isEmpty ? "Continue" : t
    }

    func closeTitle(_ block: JSONObject) -> String {
        let t = text(block["text"])
        return t.isEmpty ? "No thanks" : t
    }

    func copyTitle(_ block: JSONObject) -> String {
        if copied { return "Copied" }
        let t = text(block["copy_label"])
        return t.isEmpty ? "Copy" : t
    }

    /// Choice options for select, size, chips, rating (1 to 5) and nps (0 to 10).
    static func options(_ block: JSONObject) -> [(value: String, label: String)] {
        switch jsonString(block["input"]) ?? "" {
        case "rating": return (1 ... 5).map { (String($0), String($0)) }
        case "nps": return (0 ... 10).map { (String($0), String($0)) }
        default:
            return (block["options"] as? [Any] ?? []).map { o in
                if let d = o as? JSONObject {
                    let v = ExperienceRules.text(d["value"])
                    let l = jsonString(d["label"]).flatMap { $0.isEmpty ? nil : $0 } ?? v
                    return (v, l)
                }
                let v = ExperienceRules.text(o)
                return (v, v)
            }
        }
    }

    static func isChoice(_ block: JSONObject) -> Bool {
        return ["select", "size", "chips", "rating", "nps"].contains(jsonString(block["input"]) ?? "")
    }

    static func isCheckbox(_ block: JSONObject) -> Bool {
        return ["consent", "checkbox"].contains(jsonString(block["input"]) ?? "")
    }

    func phoneCountry(_ block: JSONObject) -> String {
        let cc = jsonString(block["default_country"]) ?? ""
        return cc.isEmpty ? "+91" : cc
    }

    // MARK: Answers

    func value(_ name: String) -> Any? {
        if name == ExperienceViewModel.otpField { return otp }
        return answers[name]
    }

    /// Typing and choosing. Doesn't re-render (the view already shows it),
    /// except for choices, whose selection is drawn by the view.
    func setAnswer(_ name: String, _ value: Any, rerender: Bool = false) {
        if name == ExperienceViewModel.otpField {
            otp = ExperienceRules.text(value)
        } else {
            answers[name] = value
        }
        invalid.remove(name)
        if rerender { onChange?() }
    }

    private func enterStep() {
        guard let step = currentStep else { return }
        for b in step.blocks where jsonString(b["type"]) == "field" {
            guard let name = jsonString(b["name"]), !name.isEmpty, answers[name] == nil else { continue }
            let input = jsonString(b["input"]) ?? "text"
            if ExperienceViewModel.isCheckbox(b) {
                answers[name] = jsonBool(b["checked"]) ?? false
            } else if input == "hidden" {
                answers[name] = ExperienceRules.text(b["value"] ?? "")
            } else if !ExperienceViewModel.isChoice(b) {
                answers[name] = ""
            }
        }
    }

    /// Checks the visible step. Sets `error` and `invalid`.
    func validate() -> Bool {
        invalid = []
        if otpPending {
            if otp.trimmingCharacters(in: .whitespaces).isEmpty {
                invalid.insert(ExperienceViewModel.otpField)
                error = Message.required
                return false
            }
            error = nil
            return true
        }
        let fields = (currentStep?.blocks ?? []).filter { jsonString($0["type"]) == "field" && jsonString($0["input"]) != "hidden" }
        for b in fields where jsonBool(b["required"]) == true {
            guard let name = jsonString(b["name"]) else { continue }
            let v = answers[name]
            let empty: Bool
            if ExperienceViewModel.isCheckbox(b) {
                empty = jsonBool(v) != true
            } else {
                empty = v == nil || ExperienceRules.text(v).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if empty { invalid.insert(name) }
        }
        if !invalid.isEmpty {
            error = Message.required
            return false
        }
        for b in fields {
            guard let name = jsonString(b["name"]) else { continue }
            let v = ExperienceRules.text(answers[name] ?? "").trimmingCharacters(in: .whitespaces)
            if v.isEmpty { continue }
            switch jsonString(b["input"]) {
            case "email":
                if v.range(of: "^[^@\\s]+@[^@\\s]+\\.[^@\\s]{2,}$", options: .regularExpression) == nil {
                    invalid.insert(name)
                    error = Message.email
                    return false
                }
            case "phone":
                if v.filter({ $0.isASCII && $0.isNumber }).count < 6 {
                    invalid.insert(name)
                    error = Message.phone
                    return false
                }
            default: break
            }
        }
        error = nil
        return true
    }

    /// The answers as sent: phone numbers with their country code.
    func fieldsForSubmit() -> JSONObject {
        var fields = answers
        for step in steps {
            for b in step.blocks where jsonString(b["type"]) == "field" && jsonString(b["input"]) == "phone" {
                guard let name = jsonString(b["name"]), let raw = fields[name] as? String else { continue }
                fields[name] = ExperienceViewModel.phoneNumber(raw, country: phoneCountry(b))
            }
        }
        return fields
    }

    static func phoneNumber(_ raw: String, country: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return "" }
        let digits = t.filter { $0.isASCII && $0.isNumber }
        if t.hasPrefix("+") { return "+" + digits }
        var local = Substring(digits)
        while local.hasPrefix("0") { local = local.dropFirst() }
        return country + local
    }

    // MARK: Actions

    func tapButton(_ block: JSONObject) {
        guard !isClosed else { return }
        let action = jsonString(block["action"]) ?? "submit"
        switch action {
        case "submit", "call_me": submit()
        case "next_step": nextStep()
        case "close": close(byUser: true)
        case "url":
            let target = jsonString(block["url"]) ?? ""
            host?.viewModel(self, clicked: target)
            if let url = URL(string: target), let scheme = url.scheme?.lowercased(), !scheme.isEmpty {
                host?.viewModel(self, open: url)
            }
            close(byUser: false)
        case "copy_code": codeCopied()
        default: break
        }
    }

    func nextStep() {
        guard validate() else {
            onChange?()
            return
        }
        if stepIndex < steps.count - 1 {
            stepIndex += 1
            enterStep()
        }
        onChange?()
    }

    /// The view copied the offer code to the clipboard.
    func codeCopied() {
        copied = true
        host?.viewModel(self, clicked: "copy_code")
        onChange?()
    }

    func submit() {
        guard !busy, !isClosed else { return }
        guard validate() else {
            onChange?()
            return
        }
        let fields = fieldsForSubmit()
        let country = (steps.flatMap { $0.blocks }.first { jsonString($0["input"]) == "phone" }).map { phoneCountry($0) } ?? "+91"
        busy = true
        error = nil
        onChange?()
        host?.viewModel(self, send: fields, otp: otpPending ? otp : nil, phoneCountry: country) { [weak self] result in
            self?.handle(result, fields: fields)
        }
    }

    func handle(_ result: ExperienceSubmitResult, fields: JSONObject) {
        busy = false
        guard !isClosed else { return }
        guard let status = result.status else {
            error = Message.offline
            onChange?()
            return
        }
        let data = result.json ?? [:]
        let errors = data["errors"] as? JSONObject ?? [:]
        if jsonBool(data["verify"]) == true {
            otpPending = true
            error = jsonString(errors[ExperienceViewModel.otpField])
            onChange?()
            return
        }
        guard jsonBool(data["ok"]) == true else {
            let first = jsonString(errors["_form"]) ?? errors.values.compactMap { jsonString($0) }.first
            error = first ?? (status == 429 ? Message.tooMany : Message.failed)
            onChange?()
            return
        }
        otpPending = false
        offer = data["offer"] as? JSONObject
        host?.viewModel(self, submitted: fields, offer: offer)
        if let next = steps.indices.first(where: { $0 > stepIndex && (steps[$0].id == "success" || !steps[$0].hasFields) }) {
            stepIndex = next
            enterStep()
            onChange?()
        } else {
            close(byUser: false)
        }
    }

    func tapOverlay() {
        if dimsBackground && closesOnOverlayTap { close(byUser: true) }
    }

    func close(byUser: Bool) {
        guard !isClosed else { return }
        isClosed = true
        host?.viewModel(self, closedByUser: byUser)
        onDismiss?()
    }
}
