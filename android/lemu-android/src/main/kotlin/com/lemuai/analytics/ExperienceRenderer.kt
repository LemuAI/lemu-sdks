package com.lemuai.analytics

import android.annotation.SuppressLint
import android.annotation.TargetApi
import android.app.Activity
import android.app.Application
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.util.LruCache
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.ViewTreeObserver
import android.widget.CheckBox
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.window.OnBackInvokedCallback
import android.window.OnBackInvokedDispatcher
import com.lemuai.analytics.core.ExperienceDisplay
import com.lemuai.analytics.core.ExperienceField
import com.lemuai.analytics.core.ExperienceOffer
import com.lemuai.analytics.core.ExperiencePresenter
import com.lemuai.analytics.core.ExperienceSubmitResult
import com.lemuai.analytics.core.ExperienceText
import java.io.ByteArrayOutputStream
import java.lang.ref.WeakReference
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

/**
 * Renders in-app messages with plain Android views in an overlay added to the current activity's
 * decor view. Follows the app from activity to activity (and through rotation) by rebuilding the
 * message on the activity that comes to the front.
 */
internal class ExperienceRenderer(app: Application) : ExperiencePresenter, Application.ActivityLifecycleCallbacks {
    private val main = Handler(Looper.getMainLooper())

    @Volatile private var current: WeakReference<Activity>? = null

    /** Main thread only. */
    private var controller: MessageController? = null

    init {
        app.registerActivityLifecycleCallbacks(this)
    }

    // ------------------------------------------------------------------ ExperiencePresenter

    override fun present(display: ExperienceDisplay): Boolean {
        val activity = current?.get() ?: return false
        if (activity.isFinishing) return false
        main.post {
            try {
                controller?.let {
                    it.detach()
                    controller = null
                }
                val c = MessageController(display, this)
                controller = c
                val target = current?.get()
                if (target == null || !c.attach(target)) {
                    controller = null
                    display.close(false)
                }
            } catch (_: Throwable) {
                controller = null
                display.close(false)
            }
        }
        return true
    }

    override fun dismiss(display: ExperienceDisplay) {
        main.post {
            val c = controller
            if (c != null && c.display === display) {
                c.dispose()
                controller = null
            }
        }
    }

    internal fun finished(c: MessageController) {
        if (controller === c) controller = null
    }

    // ------------------------------------------------------------------ activities

    private fun follow(activity: Activity) {
        current = WeakReference(activity)
        val c = controller ?: return
        if (c.activity !== activity) {
            try {
                c.detach()
                c.attach(activity)
            } catch (_: Throwable) {
            }
        }
    }

    override fun onActivityCreated(
        activity: Activity,
        savedInstanceState: Bundle?,
    ) = Unit

    override fun onActivityStarted(activity: Activity) = follow(activity)

    override fun onActivityResumed(activity: Activity) = follow(activity)

    override fun onActivityPaused(activity: Activity) = Unit

    override fun onActivityStopped(activity: Activity) {
        if (current?.get() === activity) current = null
    }

    override fun onActivitySaveInstanceState(
        activity: Activity,
        outState: Bundle,
    ) = Unit

    override fun onActivityDestroyed(activity: Activity) {
        if (current?.get() === activity) current = null
        val c = controller
        if (c != null && c.activity === activity) c.detach()
    }
}

/** The overlay root: closes a popup on the back key. */
@SuppressLint("ViewConstructor")
internal class OverlayLayout(context: Context, private val onBack: (() -> Unit)?) : FrameLayout(context) {
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (onBack != null && event.keyCode == KeyEvent.KEYCODE_BACK) {
            if (event.action == KeyEvent.ACTION_UP && !event.isCanceled) onBack.invoke()
            return true
        }
        return super.dispatchKeyEvent(event)
    }
}

/** One message on screen: its step, answers and views. Main thread only. */
internal class MessageController(
    val display: ExperienceDisplay,
    private val renderer: ExperienceRenderer,
) {
    var activity: Activity? = null
        private set

    private val main = Handler(Looper.getMainLooper())
    private val theme = display.theme
    private val format = display.format
    private val layout = display.layout
    private var root: OverlayLayout? = null
    private var body: LinearLayout? = null
    private var stepIndex = 0
    private val answers = LinkedHashMap<String, Any?>()
    private var offer: ExperienceOffer? = null
    private var otpPending = false
    private var otpError: String? = null
    private var otpInput: EditText? = null
    private var busy = false
    private var closed = false
    private var autoHideStarted = false
    private var density = 1f
    private var errorView: TextView? = null
    private val submitButtons = ArrayList<View>()
    private val stepFields = ArrayList<ExperienceField>()

    /** Value sent per field, and the value checked by validation (the phone number as typed). */
    private val readers = LinkedHashMap<String, () -> Any?>()
    private val rawReaders = LinkedHashMap<String, () -> Any?>()
    private var layoutListener: ViewTreeObserver.OnGlobalLayoutListener? = null
    private var backCallback: Any? = null
    private val autoHide = Runnable { finish(false) }

    private val isPopup: Boolean get() = format == "popup"

    // ------------------------------------------------------------------ attach and detach

    fun attach(a: Activity): Boolean {
        if (closed) return false
        val decor = a.window?.decorView as? ViewGroup ?: return false
        activity = a
        density = a.resources.displayMetrics.density
        val r = OverlayLayout(a, if (isPopup) ({ finish(true) }) else null)
        root = r
        build(a, r)
        decor.addView(r, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        val listener =
            ViewTreeObserver.OnGlobalLayoutListener {
                try {
                    val rect = Rect()
                    decor.getWindowVisibleDisplayFrame(rect)
                    val left = rect.left.coerceAtLeast(0)
                    val top = rect.top.coerceAtLeast(0)
                    val right = (decor.width - rect.right).coerceAtLeast(0)
                    val bottom = (decor.height - rect.bottom).coerceAtLeast(0)
                    if (r.paddingLeft != left || r.paddingTop != top || r.paddingRight != right || r.paddingBottom != bottom) {
                        r.setPadding(left, top, right, bottom)
                    }
                } catch (_: Throwable) {
                }
            }
        decor.viewTreeObserver.addOnGlobalLayoutListener(listener)
        layoutListener = listener
        if (isPopup) {
            r.isFocusable = true
            r.isFocusableInTouchMode = true
            r.requestFocus()
            registerBack(a)
        }
        if (format == "toast" && !autoHideStarted) {
            autoHideStarted = true
            val seconds = num(layout["auto_hide_seconds"]) ?: 8.0
            if (seconds > 0) main.postDelayed(autoHide, (seconds * 1000).toLong())
        }
        return true
    }

    /** Takes the views off the activity, keeping answers and the step for the next one. */
    fun detach() {
        collect()
        val a = activity
        val r = root
        if (a != null) {
            unregisterBack(a)
            val l = layoutListener
            if (l != null) {
                try {
                    a.window?.decorView?.viewTreeObserver?.removeOnGlobalLayoutListener(l)
                } catch (_: Throwable) {
                }
            }
        }
        layoutListener = null
        (r?.parent as? ViewGroup)?.removeView(r)
        root = null
        body = null
        activity = null
    }

    /** Removes everything without telling the engine (it asked). */
    fun dispose() {
        closed = true
        main.removeCallbacks(autoHide)
        detach()
    }

    private fun finish(byUser: Boolean) {
        if (closed) return
        closed = true
        main.removeCallbacks(autoHide)
        detach()
        renderer.finished(this)
        display.close(byUser)
    }

    private fun registerBack(a: Activity) {
        if (Build.VERSION.SDK_INT >= 33) {
            try {
                backCallback = Api33.register(a) { finish(true) }
            } catch (_: Throwable) {
            }
        }
    }

    private fun unregisterBack(a: Activity) {
        val cb = backCallback ?: return
        backCallback = null
        if (Build.VERSION.SDK_INT >= 33) {
            try {
                Api33.unregister(a, cb)
            } catch (_: Throwable) {
            }
        }
    }

    // ------------------------------------------------------------------ frame

    private fun build(
        a: Activity,
        r: OverlayLayout,
    ) {
        val screenWidth = a.resources.displayMetrics.widthPixels
        val card = FrameLayout(a)
        val scroll = ScrollView(a)
        scroll.isFillViewport = false
        val content = LinearLayout(a)
        content.orientation = LinearLayout.VERTICAL
        val closeButton = layout["close_button"] != false
        val pad =
            when (format) {
                "popup" -> dp(20)
                "slide_in" -> dp(16)
                else -> dp(12)
            }
        content.setPadding(pad, pad, if (closeButton) pad + dp(24) else pad, pad)
        scroll.addView(content, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        card.addView(scroll, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        card.isClickable = true
        if (Build.VERSION.SDK_INT >= 21) card.elevation = dp(if (format == "bar") 4 else 8).toFloat()
        body = content

        val margin = dp(16)
        val lp: FrameLayout.LayoutParams
        when (format) {
            "popup" -> {
                val overlay = layout["overlay"] != false
                r.setBackgroundColor(if (overlay) theme.overlay else Color.TRANSPARENT)
                r.isClickable = true
                r.setOnClickListener { if (layout["close_on_overlay"] != false) finish(true) }
                card.background = rounded(theme.background, dpf(theme.radius))
                lp = FrameLayout.LayoutParams(minOf(screenWidth - 2 * margin, dp(520)), ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER)
                lp.setMargins(margin, margin, margin, margin)
                card.contentDescription = null
            }
            "bar" -> {
                card.background = rounded(theme.background, 0f)
                val gravity = if (layout["position"] == "bottom") Gravity.BOTTOM else Gravity.TOP
                lp = FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, gravity)
            }
            else -> {
                // slide_in and toast: a card at the bottom.
                card.background = rounded(theme.background, dpf(theme.radius))
                val max = if (format == "toast") dp(360) else dp(420)
                val gravity = (if (layout["position"].toString().startsWith("top")) Gravity.TOP else Gravity.BOTTOM) or Gravity.CENTER_HORIZONTAL
                lp = FrameLayout.LayoutParams(minOf(screenWidth - 2 * margin, max), ViewGroup.LayoutParams.WRAP_CONTENT, gravity)
                lp.setMargins(margin, margin, margin, margin)
            }
        }
        if (closeButton) {
            val x = TextView(a)
            x.text = "×"
            x.setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
            x.setTextColor(theme.muted)
            x.gravity = Gravity.CENTER
            x.contentDescription = "Close"
            x.setOnClickListener { finish(true) }
            card.addView(x, FrameLayout.LayoutParams(dp(40), dp(40), Gravity.TOP or Gravity.END))
        }
        r.addView(card, lp)
        renderStep()
    }

    // ------------------------------------------------------------------ steps and blocks

    private fun renderStep() {
        val a = activity ?: return
        val container = body ?: return
        container.removeAllViews()
        readers.clear()
        rawReaders.clear()
        stepFields.clear()
        submitButtons.clear()
        otpInput = null
        val step = display.steps.getOrNull(stepIndex) ?: return
        val centered = (display.content["style"] as? Map<*, *>)?.get("align") == "center"
        var otpAdded = false
        for (block in step.blocks) {
            val type = block["type"] as? String ?: continue
            val view: View? =
                when (type) {
                    "heading" -> heading(a, block)
                    "text" -> text(a, block)
                    "image" -> image(a, block)
                    "button" -> button(a, block)
                    "close" -> closeLink(a, block)
                    "field" -> {
                        if (otpPending) {
                            if (otpAdded) {
                                null
                            } else {
                                otpAdded = true
                                otpField(a)
                            }
                        } else {
                            ExperienceField.of(block)?.let { field(a, it, block) }
                        }
                    }
                    "offer" -> offerView(a, block)
                    else -> null
                }
            if (view == null) continue
            if (view is TextView && (type == "heading" || type == "text")) {
                val align = block["align"] as? String
                if (align == "center" || (align == null && centered)) view.gravity = Gravity.CENTER_HORIZONTAL
            }
            add(container, view)
        }
        val err = TextView(a)
        err.setTextColor(ERROR_COLOR)
        err.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        err.visibility = View.GONE
        add(container, err)
        errorView = err
        if (otpPending && otpError != null) showError(otpError)
    }

    private fun add(
        container: LinearLayout,
        view: View,
    ) {
        val lp = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        if (container.childCount > 0) lp.topMargin = dp(10)
        container.addView(view, lp)
    }

    private fun scopes(): Map<String, Map<String, Any?>> = mapOf("answers" to answers, "offer" to (offer?.toMap() ?: emptyMap()))

    private fun textOf(value: Any?): String = ExperienceText.plain(ExperienceText.fill(value?.toString() ?: "", scopes()))

    private fun heading(
        a: Context,
        b: Map<String, Any?>,
    ): View {
        val t = TextView(a)
        t.text = textOf(b["text"])
        val level = (num(b["level"]) ?: 2.0).toInt().coerceIn(1, 3)
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, if (level == 1) 24f else if (level == 2) 20f else 17f)
        t.typeface = Typeface.DEFAULT_BOLD
        t.setTextColor(theme.text)
        return t
    }

    private fun text(
        a: Context,
        b: Map<String, Any?>,
    ): View {
        val t = TextView(a)
        t.text = textOf(b["text"])
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
        t.setTextColor(if (b["muted"] == true) theme.muted else theme.text)
        return t
    }

    private fun image(
        a: Context,
        b: Map<String, Any?>,
    ): View? {
        val url = b["url"] as? String ?: return null
        if (url.isBlank()) return null
        val iv = ImageView(a)
        iv.adjustViewBounds = true
        iv.maxHeight = dp(200)
        iv.scaleType = ImageView.ScaleType.FIT_CENTER
        iv.contentDescription = b["alt"] as? String
        iv.visibility = View.GONE
        val width = a.resources.displayMetrics.widthPixels
        ImageLoader.load(url, width) { bitmap ->
            iv.setImageBitmap(bitmap)
            iv.visibility = View.VISIBLE
        }
        return iv
    }

    private fun button(
        a: Context,
        b: Map<String, Any?>,
    ): View {
        val action = b["action"] as? String ?: "submit"
        val secondary = b["variant"] == "secondary" || action == "close"
        val t = TextView(a)
        t.text = textOf(b["text"] ?: "Continue").ifEmpty { "Continue" }
        styleButton(t, secondary)
        t.setOnClickListener {
            when (action) {
                "submit", "call_me" -> submit()
                "next_step" -> nextStep()
                "close" -> finish(true)
                "url" -> openUrl(b["url"] as? String ?: "")
                "copy_code" -> copyCode(t)
                else -> Unit
            }
        }
        if (action == "submit" || action == "call_me") submitButtons.add(t)
        return t
    }

    private fun styleButton(
        t: TextView,
        secondary: Boolean,
    ) {
        t.gravity = Gravity.CENTER
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
        t.typeface = Typeface.DEFAULT_BOLD
        t.minHeight = dp(44)
        t.setPadding(dp(16), dp(10), dp(16), dp(10))
        val radius = dpf(theme.buttonRadius)
        if (secondary || theme.outlineButtons) {
            t.background = rounded(Color.TRANSPARENT, radius, theme.primary, dp(1))
            t.setTextColor(theme.primary)
        } else {
            t.background = rounded(theme.primary, radius)
            t.setTextColor(theme.buttonText)
        }
        t.isClickable = true
        t.isFocusable = true
    }

    private fun closeLink(
        a: Context,
        b: Map<String, Any?>,
    ): View {
        val t = TextView(a)
        t.text = (b["text"] as? String)?.takeIf { it.isNotBlank() } ?: "No thanks"
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
        t.setTextColor(theme.muted)
        t.gravity = Gravity.CENTER
        t.paintFlags = t.paintFlags or Paint.UNDERLINE_TEXT_FLAG
        t.setPadding(0, dp(6), 0, dp(6))
        t.setOnClickListener { finish(true) }
        return t
    }

    private fun label(
        a: Context,
        text: String,
        required: Boolean,
    ): TextView {
        val t = TextView(a)
        t.text = if (required) "$text *" else text
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        t.setTextColor(theme.text)
        return t
    }

    private fun field(
        a: Context,
        f: ExperienceField,
        block: Map<String, Any?>,
    ): View? {
        if (f.isHidden) {
            readers[f.name] = { f.value }
            return null
        }
        stepFields.add(f)
        val prior = answers[f.name]
        if (f.isCheckbox) {
            val cb = CheckBox(a)
            cb.text = f.label
            cb.setTextColor(theme.text)
            cb.isChecked = (prior as? Boolean) ?: f.checked
            if (Build.VERSION.SDK_INT >= 21) cb.buttonTintList = ColorStateList.valueOf(theme.primary)
            readers[f.name] = { cb.isChecked }
            rawReaders[f.name] = { cb.isChecked }
            return cb
        }
        val box = LinearLayout(a)
        box.orientation = LinearLayout.VERTICAL
        if (f.label.isNotEmpty()) {
            box.addView(label(a, f.label, f.required))
        }
        if (f.isChoice) {
            var selected: String? = (prior as? String) ?: (f.value as? String)
            val row = LinearLayout(a)
            row.orientation = LinearLayout.HORIZONTAL
            val chips = ArrayList<Pair<TextView, String>>()
            fun paint() {
                for ((chip, value) in chips) {
                    val on = value == selected
                    chip.background = rounded(if (on) theme.primary else Color.TRANSPARENT, dpf(999f), theme.primary, dp(1))
                    chip.setTextColor(if (on) theme.buttonText else theme.text)
                }
            }
            for (o in f.options) {
                val chip = TextView(a)
                chip.text = o.label
                chip.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                chip.gravity = Gravity.CENTER
                chip.minWidth = dp(40)
                chip.setPadding(dp(14), dp(8), dp(14), dp(8))
                chip.setOnClickListener {
                    selected = o.value
                    paint()
                    if (block["auto_next"] == true) main.postDelayed({ nextStep() }, 150)
                }
                val lp = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
                if (chips.isNotEmpty()) lp.leftMargin = dp(8)
                row.addView(chip, lp)
                chips.add(chip to o.value)
            }
            paint()
            val scroller = HorizontalScrollView(a)
            scroller.isHorizontalScrollBarEnabled = false
            scroller.addView(row)
            val lp = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
            lp.topMargin = dp(6)
            box.addView(scroller, lp)
            readers[f.name] = { selected }
            rawReaders[f.name] = { selected }
            return box
        }
        val input = EditText(a)
        input.hint = f.placeholder
        input.setTextColor(theme.text)
        input.setHintTextColor(theme.muted)
        input.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
        input.background = rounded(theme.background, dpf(8f), theme.muted, dp(1))
        input.setPadding(dp(12), dp(10), dp(12), dp(10))
        input.inputType =
            when (f.input) {
                "email" -> InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS
                "phone" -> InputType.TYPE_CLASS_PHONE
                "number", "pincode" -> InputType.TYPE_CLASS_NUMBER
                "date" -> InputType.TYPE_CLASS_DATETIME or InputType.TYPE_DATETIME_VARIATION_DATE
                "textarea" -> InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
                else ->
                    if (f.name == "name" || f.name == "first_name" || f.name == "last_name") {
                        InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PERSON_NAME or InputType.TYPE_TEXT_FLAG_CAP_WORDS
                    } else {
                        InputType.TYPE_CLASS_TEXT
                    }
            }
        if (f.input == "textarea") {
            input.minLines = 3
            input.gravity = Gravity.TOP or Gravity.START
        } else {
            input.setSingleLine(true)
        }
        val lp = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        if (f.label.isNotEmpty()) lp.topMargin = dp(6)
        if (f.input == "phone") {
            val cc = f.defaultCountry
            val stored = prior as? String ?: ""
            input.setText(if (stored.startsWith(cc)) stored.substring(cc.length) else stored)
            val row = LinearLayout(a)
            row.orientation = LinearLayout.HORIZONTAL
            row.gravity = Gravity.CENTER_VERTICAL
            val prefix = TextView(a)
            prefix.text = cc
            prefix.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            prefix.setTextColor(theme.text)
            prefix.setPadding(0, 0, dp(8), 0)
            row.addView(prefix)
            row.addView(input, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            box.addView(row, lp)
            readers[f.name] = { ExperienceText.phoneValue(input.text.toString(), cc) }
            rawReaders[f.name] = { input.text.toString() }
        } else {
            input.setText(prior?.toString() ?: (f.value as? String ?: ""))
            box.addView(input, lp)
            readers[f.name] = { input.text.toString() }
            rawReaders[f.name] = { input.text.toString() }
        }
        return box
    }

    private fun otpField(a: Context): View {
        val box = LinearLayout(a)
        box.orientation = LinearLayout.VERTICAL
        box.addView(label(a, ExperienceText.OTP_LABEL, false))
        val input = EditText(a)
        input.inputType = InputType.TYPE_CLASS_NUMBER
        input.setSingleLine(true)
        input.setTextColor(theme.text)
        input.setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
        input.background = rounded(theme.background, dpf(8f), theme.muted, dp(1))
        input.setPadding(dp(12), dp(10), dp(12), dp(10))
        input.filters = arrayOf<android.text.InputFilter>(android.text.InputFilter.LengthFilter(6))
        val lp = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        lp.topMargin = dp(6)
        box.addView(input, lp)
        otpInput = input
        return box
    }

    private fun offerView(
        a: Context,
        b: Map<String, Any?>,
    ): View? {
        val o = offer ?: return null
        if (o.code.isNullOrEmpty() && o.headline.isNullOrEmpty()) return null
        val show = b["show"] as? String ?: "code"
        val box = LinearLayout(a)
        box.orientation = LinearLayout.VERTICAL
        box.gravity = Gravity.CENTER_HORIZONTAL
        if (!o.headline.isNullOrEmpty() && (show == "headline" || show == "both")) {
            val h = TextView(a)
            h.text = o.headline
            h.typeface = Typeface.DEFAULT_BOLD
            h.setTextColor(theme.text)
            h.gravity = Gravity.CENTER
            box.addView(h)
        }
        val code = o.code
        if (show != "headline" && !code.isNullOrEmpty()) {
            val row = LinearLayout(a)
            row.orientation = LinearLayout.HORIZONTAL
            row.gravity = Gravity.CENTER
            val c = TextView(a)
            c.text = code
            c.setTextIsSelectable(true)
            c.typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
            c.setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
            c.setTextColor(theme.text)
            c.setPadding(0, 0, dp(12), 0)
            row.addView(c)
            val copy = TextView(a)
            copy.text = (b["copy_label"] as? String)?.takeIf { it.isNotBlank() } ?: "Copy"
            styleButton(copy, true)
            copy.setOnClickListener { copyCode(copy) }
            row.addView(copy, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            val lp = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
            lp.topMargin = dp(6)
            box.addView(row, lp)
        }
        if (!o.terms.isNullOrEmpty()) {
            val t = TextView(a)
            t.text = o.terms
            t.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            t.setTextColor(theme.muted)
            t.gravity = Gravity.CENTER
            val lp = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
            lp.topMargin = dp(6)
            box.addView(t, lp)
        }
        return box
    }

    // ------------------------------------------------------------------ actions

    private fun collect() {
        for ((name, read) in readers) {
            try {
                answers[name] = read()
            } catch (_: Throwable) {
            }
        }
    }

    private fun validateStep(): String? {
        val values = LinkedHashMap<String, Any?>()
        for ((name, read) in rawReaders) {
            try {
                values[name] = read()
            } catch (_: Throwable) {
            }
        }
        return ExperienceText.validate(stepFields, values)
    }

    private fun showError(message: String?) {
        val e = errorView ?: return
        e.text = message ?: ""
        e.visibility = if (message.isNullOrEmpty()) View.GONE else View.VISIBLE
    }

    private fun nextStep() {
        if (closed || busy) return
        val err = validateStep()
        if (err != null) {
            showError(err)
            return
        }
        collect()
        if (stepIndex < display.steps.size - 1) {
            stepIndex++
            renderStep()
        }
    }

    private fun submit() {
        if (closed || busy) return
        if (otpPending) {
            val otp = otpInput?.text?.toString()?.trim() ?: ""
            if (otp.isEmpty()) {
                showError(ExperienceText.ERROR_REQUIRED)
                return
            }
            send(otp)
            return
        }
        val err = validateStep()
        if (err != null) {
            showError(err)
            return
        }
        collect()
        showError(null)
        send(null)
    }

    private fun phoneCountry(): String? {
        for (step in display.steps) {
            for (b in step.blocks) {
                if (b["type"] == "field" && b["input"] == "phone") {
                    return (b["default_country"] as? String)?.takeIf { it.isNotBlank() } ?: "+91"
                }
            }
        }
        return null
    }

    private fun send(otp: String?) {
        busy = true
        setSubmitEnabled(false)
        display.submit(LinkedHashMap(answers), otp, phoneCountry()) { result ->
            main.post { onResult(result) }
        }
    }

    private fun onResult(result: ExperienceSubmitResult) {
        busy = false
        setSubmitEnabled(true)
        if (closed) return
        when {
            result.verify -> {
                otpPending = true
                otpError = result.error
                renderStep()
            }
            !result.ok -> showError(result.error ?: ExperienceText.ERROR_GENERIC)
            else -> {
                otpPending = false
                otpError = null
                offer = result.offer
                val next = ExperienceText.stepAfterSubmit(display.steps, stepIndex)
                if (next >= 0) {
                    stepIndex = next
                    renderStep()
                } else {
                    finish(false)
                }
            }
        }
    }

    private fun setSubmitEnabled(on: Boolean) {
        for (b in submitButtons) {
            b.isEnabled = on
            b.alpha = if (on) 1f else 0.5f
        }
    }

    private fun openUrl(url: String) {
        if (url.isBlank()) return
        display.clicked(url)
        val a = activity
        try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
            a?.startActivity(intent)
        } catch (_: ActivityNotFoundException) {
        } catch (_: Throwable) {
        }
        finish(false)
    }

    private fun copyCode(button: TextView) {
        val code = offer?.code ?: return
        val a = activity ?: return
        try {
            val cm = a.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            cm?.setPrimaryClip(ClipData.newPlainText("Offer code", code))
        } catch (_: Throwable) {
        }
        button.text = "Copied"
        display.clicked("copy_code")
    }

    // ------------------------------------------------------------------ helpers

    private fun dp(value: Int): Int = (value * density + 0.5f).toInt()

    private fun dpf(value: Float): Float = value * density

    private fun rounded(
        color: Int,
        radius: Float,
        stroke: Int? = null,
        strokeWidth: Int = 0,
    ): GradientDrawable {
        val d = GradientDrawable()
        d.setColor(color)
        d.cornerRadius = radius
        if (stroke != null) d.setStroke(strokeWidth, stroke)
        return d
    }

    private fun num(value: Any?): Double? =
        when (value) {
            is Number -> value.toDouble()
            is String -> value.toDoubleOrNull()
            else -> null
        }

    companion object {
        private val ERROR_COLOR = Color.rgb(220, 38, 38)
    }
}

@TargetApi(33)
private object Api33 {
    fun register(
        activity: Activity,
        onBack: () -> Unit,
    ): Any {
        val cb = OnBackInvokedCallback { onBack() }
        activity.onBackInvokedDispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_OVERLAY, cb)
        return cb
    }

    fun unregister(
        activity: Activity,
        callback: Any,
    ) {
        val cb = callback as? OnBackInvokedCallback ?: return
        activity.onBackInvokedDispatcher.unregisterOnBackInvokedCallback(cb)
    }
}

/** Downloads message images off the main thread, scaled to the screen width. */
internal object ImageLoader {
    private const val MAX_BYTES = 8 * 1024 * 1024
    private val executor =
        Executors.newFixedThreadPool(2) { r ->
            Thread(r, "lemu-images").apply { isDaemon = true }
        }
    private val cache = LruCache<String, Bitmap>(8)
    private val main by lazy { Handler(Looper.getMainLooper()) }

    fun load(
        url: String,
        maxWidth: Int,
        done: (Bitmap) -> Unit,
    ) {
        val hit = synchronized(cache) { cache.get(url) }
        if (hit != null) {
            done(hit)
            return
        }
        try {
            executor.execute {
                val bitmap = fetch(url, maxWidth) ?: return@execute
                synchronized(cache) { cache.put(url, bitmap) }
                main.post {
                    try {
                        done(bitmap)
                    } catch (_: Throwable) {
                    }
                }
            }
        } catch (_: Throwable) {
        }
    }

    private fun fetch(
        url: String,
        maxWidth: Int,
    ): Bitmap? {
        var conn: HttpURLConnection? = null
        return try {
            conn = URL(url).openConnection() as HttpURLConnection
            conn.connectTimeout = 15_000
            conn.readTimeout = 15_000
            conn.instanceFollowRedirects = true
            if (conn.responseCode !in 200..299) return null
            val out = ByteArrayOutputStream()
            conn.inputStream.use { input ->
                val buf = ByteArray(16 * 1024)
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    out.write(buf, 0, n)
                    if (out.size() > MAX_BYTES) return null
                }
            }
            val bytes = out.toByteArray()
            val bounds = BitmapFactory.Options()
            bounds.inJustDecodeBounds = true
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            var sample = 1
            while (maxWidth > 0 && bounds.outWidth / (sample * 2) >= maxWidth) sample *= 2
            val opts = BitmapFactory.Options()
            opts.inSampleSize = sample
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)
        } catch (_: Throwable) {
            null
        } finally {
            try {
                conn?.disconnect()
            } catch (_: Throwable) {
            }
        }
    }
}
