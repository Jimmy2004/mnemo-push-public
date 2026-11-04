package dev.mnemo.push

import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.work.testing.WorkManagerTestInitHelper
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config as RConfig

/** 启动主界面不崩溃（防止布局 / 主题属性错误导致闪退）。 */
@RunWith(RobolectricTestRunner::class)
@RConfig(sdk = [34], application = App::class)
class MainActivityLaunchTest {
    @Before fun setUp() { WorkManagerTestInitHelper.initializeTestWorkManager(ApplicationProvider.getApplicationContext()) }

    @Test fun launches() {
        ActivityScenario.launch(MainActivity::class.java).use { s -> s.onActivity { it.findViewById<android.view.View>(R.id.save) } }
    }
}
