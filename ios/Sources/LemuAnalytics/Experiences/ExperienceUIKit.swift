#if canImport(UIKit) && os(iOS)
import UIKit

/*
 * Native rendering of in-app messages: a window of its own above the app
 * (passing touches through outside the message, except a popup's dimmed
 * overlay), with the experience's blocks in a card. Nothing here touches
 * `UIApplication.shared` directly, so the SDK still links in app extensions.
 */

// MARK: - App lifecycle

/// Tells the manager when the app returns to the foreground (to refresh the config) or leaves it.
final class ExperienceAppObserver {
    private var tokens: [NSObjectProtocol] = []

    init(manager: ExperienceManager) {
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak manager] _ in
            manager?.appForegrounded()
        })
        tokens.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak manager] _ in
            manager?.appBackgrounded()
        })
    }

    deinit {
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
    }
}

// MARK: - Presenter

final class UIKitExperiencePresenter: ExperiencePresenter {
    private var window: UIWindow?

    static func application() -> UIApplication? {
        let selector = NSSelectorFromString("sharedApplication")
        guard UIApplication.responds(to: selector) else { return nil }
        return UIApplication.perform(selector)?.takeUnretainedValue() as? UIApplication
    }

    static func activeScene() -> UIWindowScene? {
        guard let app = application(),
              let scenes = app.value(forKey: "connectedScenes") as? Set<UIScene>
        else { return nil }
        let windowScenes = scenes.compactMap { $0 as? UIWindowScene }
        return windowScenes.first { $0.activationState == .foregroundActive }
            ?? windowScenes.first { $0.activationState == .foregroundInactive }
            ?? windowScenes.first
    }

    func present(_ model: ExperienceViewModel) -> Bool {
        guard window == nil else { return false }
        let scene = UIKitExperiencePresenter.activeScene()
        let previousKey = scene?.windows.first { $0.isKeyWindow }
        let w: ExperienceWindow
        if let scene = scene {
            w = ExperienceWindow(windowScene: scene)
        } else {
            w = ExperienceWindow(frame: UIScreen.main.bounds)
        }
        let controller = ExperienceViewController(model: model)
        controller.hostStatusBarStyle = previousKey?.rootViewController?.preferredStatusBarStyle ?? .default
        w.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 10)
        w.backgroundColor = .clear
        w.rootViewController = controller
        model.onDismiss = { [weak self, weak w, weak previousKey] in
            controller.animateOut {
                w?.isHidden = true
                if self?.window === w { self?.window = nil }
                previousKey?.makeKey()
            }
        }
        window = w
        w.makeKeyAndVisible()
        controller.animateIn()
        return true
    }

    func open(_ url: URL) {
        if let scene = UIKitExperiencePresenter.activeScene() {
            scene.open(url, options: nil, completionHandler: nil)
        }
    }
}

/// Touches outside the message reach the app underneath.
final class ExperienceWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit === self || hit is ExperiencePassthroughView { return nil }
        return hit
    }
}

final class ExperiencePassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// A button that runs a closure.
final class ExperienceButton: UIButton {
    var onTap: (() -> Void)?
    /// Space around the title (instead of the deprecated contentEdgeInsets).
    var padding: UIEdgeInsets = .zero {
        didSet { invalidateIntrinsicContentSize() }
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + padding.left + padding.right, height: size.height + padding.top + padding.bottom)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    @objc private func tapped() {
        onTap?()
    }
}

/// A text field that reports each change.
final class ExperienceTextField: UITextField {
    var onChange: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addTarget(self, action: #selector(changed), for: .editingChanged)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addTarget(self, action: #selector(changed), for: .editingChanged)
    }

    @objc private func changed() {
        onChange?(text ?? "")
    }
}

/// A switch that reports each change.
final class ExperienceSwitch: UISwitch {
    var onChange: ((Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addTarget(self, action: #selector(changed), for: .valueChanged)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addTarget(self, action: #selector(changed), for: .valueChanged)
    }

    @objc private func changed() {
        onChange?(isOn)
    }
}

extension ExperienceColor {
    var uiColor: UIColor {
        return UIColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }
}

// MARK: - View controller

final class ExperienceViewController: UIViewController, UITextFieldDelegate {
    private let model: ExperienceViewModel
    private let area = ExperiencePassthroughView()
    private let card = UIView()
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let closeButton = ExperienceButton(type: .system)
    private var overlay: UIControl?
    private var areaBottom: NSLayoutConstraint?
    private var keyboardToken: NSObjectProtocol?
    var hostStatusBarStyle: UIStatusBarStyle = .default

    private var theme: ExperienceTheme { return model.theme }
    private var isBar: Bool { return model.format == "bar" }
    private var padding: CGFloat { return isBar || model.format == "toast" ? 14 : 20 }
    private var centered: Bool { return jsonString(model.variant.style["align"]) == "center" }

    init(model: ExperienceViewModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    deinit {
        if let token = keyboardToken { NotificationCenter.default.removeObserver(token) }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return hostStatusBarStyle
    }

    override func loadView() {
        view = ExperiencePassthroughView()
        view.backgroundColor = .clear
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if model.dimsBackground {
            let o = UIControl()
            o.backgroundColor = theme.overlay.uiColor
            o.translatesAutoresizingMaskIntoConstraints = false
            o.addTarget(self, action: #selector(overlayTapped), for: .touchUpInside)
            o.isAccessibilityElement = false
            view.addSubview(o)
            NSLayoutConstraint.activate([
                o.topAnchor.constraint(equalTo: view.topAnchor),
                o.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                o.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                o.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
            overlay = o
        }
        area.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(area)
        let safe = view.safeAreaLayoutGuide
        let bottom = area.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        areaBottom = bottom
        NSLayoutConstraint.activate([
            area.topAnchor.constraint(equalTo: view.topAnchor),
            area.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            area.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            bottom,
        ])
        buildCard()
        model.onChange = { [weak self] in self?.render() }
        render()
        keyboardToken = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main
        ) { [weak self] note in self?.keyboardChanged(note) }
        if model.autoHideSeconds > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + model.autoHideSeconds) { [weak self] in
                self?.model.close(byUser: false)
            }
        }
    }

    private func buildCard() {
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = theme.background.uiColor
        card.layer.cornerRadius = isBar ? 0 : CGFloat(min(theme.radius, 32))
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.18
        card.layer.shadowRadius = 16
        card.layer.shadowOffset = CGSize(width: 0, height: 6)
        if model.format == "popup" { card.accessibilityViewIsModal = true }
        area.addSubview(card)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = false
        scroll.keyboardDismissMode = .interactive
        scroll.layer.cornerRadius = card.layer.cornerRadius
        scroll.clipsToBounds = true
        card.addSubview(scroll)

        stack.axis = .vertical
        stack.spacing = isBar ? 8 : 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setTitle("\u{00D7}", for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 26, weight: .regular)
        closeButton.setTitleColor(theme.muted.uiColor, for: .normal)
        closeButton.accessibilityLabel = "Close"
        closeButton.onTap = { [weak self] in self?.model.close(byUser: true) }
        card.addSubview(closeButton)

        let content = scroll.contentLayoutGuide
        let frame = scroll.frameLayoutGuide
        let showsClose = model.showsCloseButton
        let trailingPad: CGFloat = showsClose ? 40 : padding
        var constraints: [NSLayoutConstraint] = [
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -trailingPad),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -padding),
            stack.widthAnchor.constraint(equalTo: frame.widthAnchor, constant: -(padding + trailingPad)),
            closeButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -2),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
        ]
        // The card is as tall as its content, up to the space available.
        let fit = scroll.heightAnchor.constraint(equalTo: content.heightAnchor)
        fit.priority = .defaultHigh
        constraints.append(fit)

        let safe = view.safeAreaLayoutGuide
        if isBar {
            constraints += [
                card.topAnchor.constraint(equalTo: view.topAnchor),
                card.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                card.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                card.bottomAnchor.constraint(lessThanOrEqualTo: area.bottomAnchor),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: padding),
                // Content starts below the status bar; the bar's colour fills behind it.
                scroll.topAnchor.constraint(equalTo: safe.topAnchor),
                closeButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 2),
            ]
            let cover = UIView()
            cover.translatesAutoresizingMaskIntoConstraints = false
            cover.backgroundColor = theme.background.uiColor
            card.insertSubview(cover, at: 0)
            constraints += [
                cover.topAnchor.constraint(equalTo: card.topAnchor),
                cover.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                cover.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                cover.bottomAnchor.constraint(equalTo: safe.topAnchor),
            ]
        } else {
            let maxWidth: CGFloat = model.format == "toast" ? 420 : 520
            let width = card.widthAnchor.constraint(equalTo: area.widthAnchor, constant: -32)
            width.priority = .defaultHigh
            constraints += [
                scroll.topAnchor.constraint(equalTo: card.topAnchor),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: padding),
                closeButton.topAnchor.constraint(equalTo: card.topAnchor, constant: 2),
                card.centerXAnchor.constraint(equalTo: area.centerXAnchor),
                card.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),
                card.widthAnchor.constraint(lessThanOrEqualTo: area.widthAnchor, constant: -32),
                width,
                card.topAnchor.constraint(greaterThanOrEqualTo: safe.topAnchor, constant: 16),
                card.bottomAnchor.constraint(lessThanOrEqualTo: area.bottomAnchor, constant: -16),
            ]
            if model.format == "popup" {
                let center = card.centerYAnchor.constraint(equalTo: area.centerYAnchor)
                center.priority = .defaultHigh
                constraints.append(center)
            } else {
                // slide_in and toast sit at the bottom, above the home indicator and the keyboard.
                let bottom = card.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -16)
                bottom.priority = .defaultHigh
                constraints.append(bottom)
            }
        }
        NSLayoutConstraint.activate(constraints)
    }

    // MARK: Rendering

    private func render() {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        closeButton.isHidden = !model.showsCloseButton
        for block in model.blocks {
            if let v = view(for: block) { stack.addArrangedSubview(v) }
        }
        if let error = model.error, !error.isEmpty {
            let label = makeLabel(error, size: 14, weight: .regular, color: UIColor(red: 0.86, green: 0.15, blue: 0.15, alpha: 1))
            label.accessibilityTraits = .staticText
            stack.addArrangedSubview(label)
            UIAccessibility.post(notification: .announcement, argument: error)
        }
    }

    private func alignment(_ block: JSONObject) -> NSTextAlignment {
        switch jsonString(block["align"]) {
        case "center": return .center
        case "right": return .right
        case "left": return .left
        default: return centered ? .center : .natural
        }
    }

    private func makeLabel(_ text: String, size: CGFloat, weight: UIFont.Weight, color: UIColor, align: NSTextAlignment = .natural) -> UILabel {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.textAlignment = align
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    private func view(for block: JSONObject) -> UIView? {
        switch jsonString(block["type"]) ?? "" {
        case "heading":
            let level = Int(jsonNumber(block["level"]) ?? 2)
            let size: CGFloat = level <= 1 ? 24 : level == 2 ? 20 : 17
            let label = makeLabel(model.text(block["text"]), size: size, weight: .bold, color: theme.text.uiColor, align: alignment(block))
            label.accessibilityTraits = .header
            return label
        case "text":
            let muted = jsonBool(block["muted"]) == true
            return makeLabel(model.text(block["text"]), size: 15, weight: .regular, color: muted ? theme.muted.uiColor : theme.text.uiColor, align: alignment(block))
        case "image":
            return imageView(block)
        case "button":
            return button(block)
        case "close":
            let b = ExperienceButton(type: .system)
            b.setTitle(model.closeTitle(block), for: .normal)
            b.setTitleColor(theme.muted.uiColor, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 14)
            b.onTap = { [weak self] in self?.model.close(byUser: true) }
            return b
        case "field":
            return field(block)
        case "offer":
            return offerView(block)
        default:
            return nil
        }
    }

    private func imageView(_ block: JSONObject) -> UIView? {
        guard let raw = jsonString(block["url"]), let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else { return nil }
        let image = UIImageView()
        image.contentMode = .scaleAspectFit
        image.clipsToBounds = true
        image.isAccessibilityElement = !(jsonString(block["alt"]) ?? "").isEmpty
        image.accessibilityLabel = jsonString(block["alt"])
        image.heightAnchor.constraint(equalToConstant: 160).isActive = true
        URLSession.shared.dataTask(with: url) { [weak image] data, _, _ in
            let loaded = data.flatMap { UIImage(data: $0) }
            DispatchQueue.main.async {
                if let loaded = loaded { image?.image = loaded } else { image?.isHidden = true }
            }
        }.resume()
        return image
    }

    private func styleButton(_ b: ExperienceButton, primary: Bool) {
        b.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        b.layer.cornerRadius = CGFloat(min(theme.buttonRadius, 23))
        b.padding = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        if primary {
            b.backgroundColor = theme.primary.uiColor
            b.setTitleColor(theme.buttonText.uiColor, for: .normal)
        } else {
            b.backgroundColor = .clear
            b.layer.borderWidth = 1
            b.layer.borderColor = theme.primary.uiColor.cgColor
            b.setTitleColor(theme.primary.uiColor, for: .normal)
        }
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true
    }

    private func button(_ block: JSONObject) -> UIView {
        let action = jsonString(block["action"]) ?? "submit"
        let b = ExperienceButton(type: .custom)
        b.setTitle(action == "copy_code" ? model.copyTitle(block) : model.buttonTitle(block), for: .normal)
        b.titleLabel?.numberOfLines = 0
        b.titleLabel?.textAlignment = .center
        let primary = jsonString(block["variant"]) != "secondary" && action != "close"
        styleButton(b, primary: primary)
        let submits = action == "submit" || action == "call_me"
        if submits && model.busy {
            b.isEnabled = false
            b.alpha = 0.6
        }
        b.onTap = { [weak self] in
            guard let self = self else { return }
            self.view.endEditing(true)
            if action == "copy_code", let code = self.model.offerCode { UIPasteboard.general.string = code }
            self.model.tapButton(block)
        }
        return b
    }

    private func field(_ block: JSONObject) -> UIView? {
        guard let name = jsonString(block["name"]), !name.isEmpty else { return nil }
        let required = jsonBool(block["required"]) == true
        let labelText = model.text(block["label"])
        let invalid = model.invalid.contains(name)
        let column = UIStackView()
        column.axis = .vertical
        column.spacing = 6

        if ExperienceViewModel.isCheckbox(block) {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 10
            row.alignment = .center
            let toggle = ExperienceSwitch()
            toggle.isOn = jsonBool(model.value(name)) == true
            toggle.onTintColor = theme.primary.uiColor
            toggle.onChange = { [weak self] on in self?.model.setAnswer(name, on) }
            toggle.accessibilityLabel = labelText
            let label = makeLabel(labelText + (required ? " *" : ""), size: 14, weight: .regular, color: invalid ? UIColor.systemRed : theme.text.uiColor)
            row.addArrangedSubview(toggle)
            row.addArrangedSubview(label)
            return row
        }

        if !labelText.isEmpty {
            column.addArrangedSubview(makeLabel(labelText + (required ? " *" : ""), size: 14, weight: .medium, color: theme.text.uiColor))
        }

        if ExperienceViewModel.isChoice(block) {
            let chips = UIScrollView()
            chips.showsHorizontalScrollIndicator = false
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 8
            row.translatesAutoresizingMaskIntoConstraints = false
            chips.addSubview(row)
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: chips.contentLayoutGuide.topAnchor),
                row.bottomAnchor.constraint(equalTo: chips.contentLayoutGuide.bottomAnchor),
                row.leadingAnchor.constraint(equalTo: chips.contentLayoutGuide.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: chips.contentLayoutGuide.trailingAnchor),
                row.heightAnchor.constraint(equalTo: chips.frameLayoutGuide.heightAnchor),
                chips.heightAnchor.constraint(equalToConstant: 40),
            ])
            let selected = model.value(name).map { ExperienceRules.text($0) }
            for option in ExperienceViewModel.options(block) {
                let chip = ExperienceButton(type: .custom)
                chip.setTitle(option.label, for: .normal)
                chip.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
                chip.padding = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
                chip.layer.cornerRadius = 18
                chip.layer.borderWidth = 1
                let on = selected == option.value
                chip.layer.borderColor = (invalid ? UIColor.systemRed : theme.primary.uiColor).cgColor
                chip.backgroundColor = on ? theme.primary.uiColor : .clear
                chip.setTitleColor(on ? theme.buttonText.uiColor : theme.text.uiColor, for: .normal)
                chip.accessibilityTraits = on ? [.button, .selected] : .button
                chip.onTap = { [weak self] in self?.model.setAnswer(name, option.value, rerender: true) }
                row.addArrangedSubview(chip)
            }
            column.addArrangedSubview(chips)
            return column
        }

        let input = jsonString(block["input"]) ?? "text"
        let textField = ExperienceTextField()
        textField.delegate = self
        textField.text = model.value(name).map { ExperienceRules.text($0) }
        textField.placeholder = model.text(block["placeholder"])
        textField.textColor = theme.text.uiColor
        textField.font = .systemFont(ofSize: 16)
        textField.borderStyle = .none
        textField.layer.cornerRadius = 8
        textField.layer.borderWidth = 1
        textField.layer.borderColor = (invalid ? UIColor.systemRed : theme.muted.uiColor.withAlphaComponent(0.5)).cgColor
        textField.accessibilityLabel = labelText.isEmpty ? textField.placeholder : labelText
        textField.heightAnchor.constraint(equalToConstant: 46).isActive = true
        let pad = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 46))
        textField.leftView = pad
        textField.leftViewMode = .always
        textField.returnKeyType = .done
        switch input {
        case "email":
            textField.keyboardType = .emailAddress
            textField.textContentType = .emailAddress
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
        case "phone":
            textField.keyboardType = .phonePad
            textField.textContentType = .telephoneNumber
            let prefix = UILabel(frame: CGRect(x: 0, y: 0, width: 56, height: 46))
            prefix.text = model.phoneCountry(block)
            prefix.textAlignment = .center
            prefix.font = .systemFont(ofSize: 16)
            prefix.textColor = theme.muted.uiColor
            textField.leftView = prefix
        case "number":
            textField.keyboardType = .decimalPad
        case "pincode":
            textField.keyboardType = .numberPad
            textField.textContentType = .postalCode
        case "otp":
            textField.keyboardType = .numberPad
            textField.textContentType = .oneTimeCode
        default:
            if name == "name" || name == "first_name" {
                textField.autocapitalizationType = .words
                textField.textContentType = name == "name" ? .name : .givenName
            }
        }
        textField.onChange = { [weak self] text in self?.model.setAnswer(name, text) }
        column.addArrangedSubview(textField)
        return column
    }

    private func offerView(_ block: JSONObject) -> UIView? {
        guard model.hasOffer else { return nil }
        let offer = model.offer ?? [:]
        let column = UIStackView()
        column.axis = .vertical
        column.spacing = 8
        column.alignment = .center
        let show = jsonString(block["show"]) ?? "code"
        if show == "headline" || show == "both", let headline = jsonString(offer["headline"]), !headline.isEmpty {
            column.addArrangedSubview(makeLabel(headline, size: 16, weight: .semibold, color: theme.text.uiColor, align: .center))
        }
        if show != "headline", let code = model.offerCode {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 12
            row.alignment = .center
            let codeLabel = makeLabel(code, size: 20, weight: .bold, color: theme.text.uiColor, align: .center)
            codeLabel.font = .monospacedDigitSystemFont(ofSize: 20, weight: .bold)
            let copy = ExperienceButton(type: .custom)
            copy.setTitle(model.copyTitle(block), for: .normal)
            styleButton(copy, primary: false)
            copy.onTap = { [weak self] in
                UIPasteboard.general.string = code
                self?.model.codeCopied()
            }
            row.addArrangedSubview(codeLabel)
            row.addArrangedSubview(copy)
            column.addArrangedSubview(row)
        }
        if let terms = jsonString(offer["terms"]), !terms.isEmpty {
            column.addArrangedSubview(makeLabel(terms, size: 12, weight: .regular, color: theme.muted.uiColor, align: .center))
        }
        return column
    }

    // MARK: Events

    @objc private func overlayTapped() {
        view.endEditing(true)
        model.tapOverlay()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    private func keyboardChanged(_ note: Notification) {
        guard let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let local = view.convert(end, from: nil)
        let overlap = max(0, view.bounds.maxY - local.minY)
        areaBottom?.constant = -overlap
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        UIView.animate(withDuration: duration) { self.view.layoutIfNeeded() }
    }

    // MARK: Animation

    func animateIn() {
        view.layoutIfNeeded()
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        overlay?.alpha = 0
        card.alpha = 0
        if !reduceMotion {
            let offset: CGFloat = isBar ? -card.bounds.height : model.format == "popup" ? 0 : 40
            card.transform = model.format == "popup" ? CGAffineTransform(scaleX: 0.96, y: 0.96) : CGAffineTransform(translationX: 0, y: offset)
        }
        UIView.animate(withDuration: reduceMotion ? 0.1 : 0.22, delay: 0, options: [.curveEaseOut], animations: {
            self.overlay?.alpha = 1
            self.card.alpha = 1
            self.card.transform = .identity
        }, completion: { _ in
            UIAccessibility.post(notification: .screenChanged, argument: self.card)
        })
    }

    func animateOut(_ done: @escaping () -> Void) {
        view.endEditing(true)
        UIView.animate(withDuration: 0.18, animations: {
            self.overlay?.alpha = 0
            self.card.alpha = 0
        }, completion: { _ in done() })
    }
}
#endif
