package dev.mnemo.push

import android.app.Application
import com.google.android.material.color.DynamicColors

class App : Application() {
    override fun onCreate() {
        super.onCreate()
        DynamicColors.applyToActivitiesIfAvailable(this)   // Android 12+ 跟随壁纸取色
    }
}
