package com.lemuai.analytics.sample

import android.app.Application
import com.lemuai.analytics.Lemu
import com.lemuai.analytics.LemuOptions

class SampleApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Lemu.setup(
            this,
            BuildConfig.LEMU_WRITE_KEY,
            LemuOptions(
                apiHost = BuildConfig.LEMU_API_HOST,
                debug = true,
                trackActivityScreens = true,
            ),
        )
    }
}
