package com.lemuai.analytics

import android.content.Context
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerStateListener
import com.lemuai.analytics.core.InstallReferrerSource

/**
 * Reads the Play install referrer. The library is a compileOnly dependency: this class is only
 * loaded after [isAvailable] confirms the app ships `com.android.installreferrer:installreferrer`.
 */
internal class PlayInstallReferrer(private val context: Context) : InstallReferrerSource {
    override fun fetch(onResult: (String?) -> Unit) {
        val client = InstallReferrerClient.newBuilder(context.applicationContext).build()
        var delivered = false
        val deliver = { value: String? ->
            if (!delivered) {
                delivered = true
                onResult(value)
            }
        }
        client.startConnection(
            object : InstallReferrerStateListener {
                override fun onInstallReferrerSetupFinished(responseCode: Int) {
                    var referrer: String? = null
                    try {
                        if (responseCode == InstallReferrerClient.InstallReferrerResponse.OK) {
                            referrer = client.installReferrer?.installReferrer
                        }
                    } catch (_: Throwable) {
                    } finally {
                        try {
                            client.endConnection()
                        } catch (_: Throwable) {
                        }
                        deliver(referrer)
                    }
                }

                override fun onInstallReferrerServiceDisconnected() {
                    deliver(null)
                }
            },
        )
    }

    companion object {
        fun isAvailable(): Boolean =
            try {
                Class.forName("com.android.installreferrer.api.InstallReferrerClient")
                true
            } catch (_: Throwable) {
                false
            }
    }
}
