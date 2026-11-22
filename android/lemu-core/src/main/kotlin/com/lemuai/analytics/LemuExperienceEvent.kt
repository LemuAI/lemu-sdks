package com.lemuai.analytics

/**
 * Something that happened to an in-app message: it was shown, closed, submitted, or a link or
 * copy button in it was tapped. Delivered to [LemuExperienceListener] on the main thread.
 *
 * @property type what happened.
 * @property experience the experience's key, as set in Lemu.
 * @property variant the variant the user saw.
 * @property byUser for [Type.CLOSED]: true when the user closed it (not when it hid itself).
 * @property target for [Type.CLICKED]: the URL that was opened, or `copy_code`.
 * @property fields for [Type.SUBMITTED]: the values the user entered, by field name.
 * @property offerCode for [Type.SUBMITTED]: the offer code Lemu returned, if any.
 */
class LemuExperienceEvent(
    val type: Type,
    val experience: String,
    val variant: String,
    val byUser: Boolean = false,
    val target: String? = null,
    val fields: Map<String, Any?> = emptyMap(),
    val offerCode: String? = null,
) {
    enum class Type { SHOWN, CLOSED, SUBMITTED, CLICKED }

    override fun toString(): String = "LemuExperienceEvent($type, $experience, $variant)"
}

/**
 * Callbacks for in-app messages, set with `Lemu.experiences.setListener(...)`. Every method has an
 * empty default, so override only what you need. Called on the main thread.
 */
interface LemuExperienceListener {
    fun onShown(event: LemuExperienceEvent) {}

    fun onClosed(event: LemuExperienceEvent) {}

    fun onSubmitted(event: LemuExperienceEvent) {}

    fun onClicked(event: LemuExperienceEvent) {}
}
