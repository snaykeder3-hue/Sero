#!/bin/bash
# Fire Kumanda projesini tek dosyadan olusturur (GitHub Actions bunu calistirir).
set -e
mkdir -p 'app'
cat > 'app/build.gradle.kts' <<'END_OF_FILE_XYZ'
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.example.fireremote"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.example.fireremote"
        minSdk = 24
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
}
END_OF_FILE_XYZ
mkdir -p 'app/src/main'
cat > 'app/src/main/AndroidManifest.xml' <<'END_OF_FILE_XYZ'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30" />
    <uses-permission android:name="android.permission.BLUETOOTH_SCAN"
        android:usesPermissionFlags="neverForLocation" />
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />

    <uses-feature android:name="android.hardware.bluetooth_le" android:required="false" />

    <application
        android:allowBackup="true"
        android:label="@string/app_name"
        android:theme="@style/Theme.AppCompat.DayNight.DarkActionBar">

        <activity android:name=".MainActivity" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
                <category android:name="android.intent.category.LEANBACK_LAUNCHER" />
            </intent-filter>
        </activity>

        <!-- Uygulama arka planda/kapalıyken de kumanda tuşlarını işler -->
        <service
            android:name=".RemoteKeyService"
            android:exported="true"
            android:label="@string/service_label"
            android:permission="android.permission.BIND_ACCESSIBILITY_SERVICE">
            <intent-filter>
                <action android:name="android.accessibilityservice.AccessibilityService" />
            </intent-filter>
            <meta-data
                android:name="android.accessibilityservice"
                android:resource="@xml/accessibility_service_config" />
        </service>
    </application>
</manifest>
END_OF_FILE_XYZ
mkdir -p 'app/src/main/java/com/example/fireremote'
cat > 'app/src/main/java/com/example/fireremote/KeyBus.kt' <<'END_OF_FILE_XYZ'
package com.example.fireremote

import android.view.InputDevice
import android.view.KeyEvent

/** Servis ile ekran arasında tuş olaylarını taşıyan basit köprü. */
object KeyBus {
    @Volatile var serviceActive = false
    @Volatile var listener: ((String) -> Unit)? = null

    private val REMOTE_NAME = Regex("fire|amazon|alexa|remote", RegexOption.IGNORE_CASE)

    fun deviceName(e: KeyEvent): String =
        InputDevice.getDevice(e.deviceId)?.name ?: "?"

    fun isFireRemote(e: KeyEvent): Boolean = REMOTE_NAME.containsMatchIn(deviceName(e))

    fun describe(e: KeyEvent): String =
        "${KeyEvent.keyCodeToString(e.keyCode)}  ←  ${deviceName(e)}"

    fun emit(line: String) {
        listener?.invoke(line)
    }
}
END_OF_FILE_XYZ
mkdir -p 'app/src/main/java/com/example/fireremote'
cat > 'app/src/main/java/com/example/fireremote/MainActivity.kt' <<'END_OF_FILE_XYZ'
package com.example.fireremote

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.KeyEvent
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.ListView
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.widget.SwitchCompat
import androidx.core.content.ContextCompat

@SuppressLint("MissingPermission")
class MainActivity : AppCompatActivity() {

    private val btAdapter: BluetoothAdapter? by lazy {
        (getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
    }
    private val found = LinkedHashMap<String, BluetoothDevice>()
    private var shown: List<BluetoothDevice> = emptyList()
    private val handler = Handler(Looper.getMainLooper())
    private var scanning = false

    private lateinit var listAdapter: ArrayAdapter<String>
    private lateinit var statusView: TextView
    private lateinit var logView: TextView
    private lateinit var filterSwitch: SwitchCompat
    private lateinit var accessButton: Button

    private val permLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { r ->
            if (r.values.all { it }) startScan() else setStatus("Bluetooth izni gerekli")
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        statusView = findViewById(R.id.status)
        logView = findViewById(R.id.log)
        filterSwitch = findViewById(R.id.switchFilter)
        accessButton = findViewById(R.id.btnAccess)

        listAdapter = ArrayAdapter(this, android.R.layout.simple_list_item_1, mutableListOf<String>())
        findViewById<ListView>(R.id.deviceList).apply {
            adapter = listAdapter
            setOnItemClickListener { _, _, pos, _ -> pair(shown[pos]) }
        }
        findViewById<Button>(R.id.btnScan).setOnClickListener { startScan() }
        accessButton.setOnClickListener {
            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
        }
        filterSwitch.setOnCheckedChangeListener { _, _ -> refreshList() }

        ContextCompat.registerReceiver(
            this, bondReceiver,
            IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED),
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
    }

    override fun onResume() {
        super.onResume()
        KeyBus.listener = { line -> runOnUiThread { appendLog(line) } }
        accessButton.text =
            "Genel tuş işleme: " + if (KeyBus.serviceActive) "AÇIK" else "KAPALI (aç)"
    }

    override fun onPause() {
        KeyBus.listener = null
        super.onPause()
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        stopScan()
        unregisterReceiver(bondReceiver)
        super.onDestroy()
    }

    /** Erişilebilirlik servisi kapalıyken tuşları sadece bu ekranda yakalar. */
    override fun dispatchKeyEvent(e: KeyEvent): Boolean {
        if (!KeyBus.serviceActive && e.action == KeyEvent.ACTION_DOWN && e.repeatCount == 0) {
            appendLog(KeyBus.describe(e))
        }
        return super.dispatchKeyEvent(e)
    }

    // ---------------- Arama ----------------

    private fun requiredPermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= 31)
            arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)

    private fun hasPermissions() = requiredPermissions().all {
        ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) = add(result.device)
        override fun onBatchScanResults(results: MutableList<ScanResult>) =
            results.forEach { add(it.device) }
        override fun onScanFailed(errorCode: Int) = setStatus("Tarama hatası: $errorCode")
        private fun add(d: BluetoothDevice) {
            if (found.put(d.address, d) == null) refreshList()
        }
    }

    private fun startScan() {
        val adapter = btAdapter
        if (adapter == null || !adapter.isEnabled) { setStatus("Bluetooth kapalı"); return }
        if (!hasPermissions()) { permLauncher.launch(requiredPermissions()); return }

        adapter.bondedDevices.forEach { found[it.address] = it } // zaten eşleşmişler
        refreshList()
        if (scanning) return
        scanning = true
        adapter.bluetoothLeScanner?.startScan(scanCallback)
        setStatus("Aranıyor… Kumandada Home tuşunu 10 sn basılı tutun (eşleşme modu)")
        handler.postDelayed({ stopScan() }, 20_000)
    }

    private fun stopScan() {
        if (!scanning) return
        scanning = false
        try { btAdapter?.bluetoothLeScanner?.stopScan(scanCallback) } catch (_: Exception) {}
        setStatus("Tarama bitti")
    }

    private fun looksLikeRemote(d: BluetoothDevice): Boolean =
        d.name?.contains(Regex("fire|amazon|alexa|remote", RegexOption.IGNORE_CASE)) == true

    private fun refreshList() {
        shown = found.values.filter { !filterSwitch.isChecked || looksLikeRemote(it) }
        listAdapter.clear()
        listAdapter.addAll(shown.map {
            val bonded = if (it.bondState == BluetoothDevice.BOND_BONDED) "  • eşleşmiş" else ""
            "${it.name ?: "(adsız)"}\n${it.address}$bonded"
        })
    }

    // ---------------- Eşleştirme ----------------

    private fun pair(d: BluetoothDevice) {
        stopScan()
        if (d.bondState == BluetoothDevice.BOND_BONDED) {
            setStatus("Zaten eşleşmiş: ${d.name}. Tuşlara basın.")
        } else {
            setStatus("Eşleşiliyor: ${d.name}…")
            d.createBond()
        }
    }

    private val bondReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val d = deviceFrom(intent) ?: return
            when (intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.ERROR)) {
                BluetoothDevice.BOND_BONDED -> setStatus("Eşleşti: ${d.name}. Tuşlara basın.")
                BluetoothDevice.BOND_NONE -> setStatus("Eşleşme yok/başarısız: ${d.name}")
            }
            found[d.address] = d
            refreshList()
        }
    }

    @Suppress("DEPRECATION")
    private fun deviceFrom(i: Intent): BluetoothDevice? =
        if (Build.VERSION.SDK_INT >= 33)
            i.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
        else i.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)

    // ---------------- UI yardımcıları ----------------

    private fun setStatus(s: String) = runOnUiThread { statusView.text = s }

    private fun appendLog(line: String) {
        logView.text = "$line\n${logView.text}".take(3000)
    }
}
END_OF_FILE_XYZ
mkdir -p 'app/src/main/java/com/example/fireremote'
cat > 'app/src/main/java/com/example/fireremote/RemoteKeyService.kt' <<'END_OF_FILE_XYZ'
package com.example.fireremote

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.view.KeyEvent
import android.view.accessibility.AccessibilityEvent

/**
 * Fire kumandasından gelen tuşları sistem genelinde yakalar (uygulama açık olmasa da).
 * Etkinleştirme: Ayarlar > Erişilebilirlik > Fire Kumanda Tuş İşleme.
 */
class RemoteKeyService : AccessibilityService() {

    override fun onServiceConnected() {
        KeyBus.serviceActive = true
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
    override fun onInterrupt() {}

    override fun onUnbind(intent: Intent?): Boolean {
        KeyBus.serviceActive = false
        return super.onUnbind(intent)
    }

    /** true dönersen tuş tüketilir (başka uygulamaya gitmez), false dönersen normal akar. */
    override fun onKeyEvent(event: KeyEvent): Boolean {
        val down = event.action == KeyEvent.ACTION_DOWN
        if (down && event.repeatCount == 0) KeyBus.emit(KeyBus.describe(event))

        if (!KeyBus.isFireRemote(event)) return false
        return handleKey(event, down)
    }

    // ---- Tuş eşlemeleri: kendi ihtiyacına göre değiştir ----
    private fun handleKey(event: KeyEvent, down: Boolean): Boolean {
        val action = when (event.keyCode) {
            KeyEvent.KEYCODE_MENU -> GLOBAL_ACTION_RECENTS
            KeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> GLOBAL_ACTION_NOTIFICATIONS
            KeyEvent.KEYCODE_MEDIA_REWIND -> GLOBAL_ACTION_QUICK_SETTINGS
            // KeyEvent.KEYCODE_BACK -> GLOBAL_ACTION_BACK
            // KeyEvent.KEYCODE_HOME -> GLOBAL_ACTION_HOME
            else -> return false // yön tuşları, OK, oynat/duraklat vb. normal çalışsın
        }
        if (down && event.repeatCount == 0) performGlobalAction(action)
        return true
    }
}
END_OF_FILE_XYZ
mkdir -p 'app/src/main/res/layout'
cat > 'app/src/main/res/layout/activity_main.xml' <<'END_OF_FILE_XYZ'
<?xml version="1.0" encoding="utf-8"?>
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:layout_width="match_parent"
    android:layout_height="match_parent"
    android:orientation="vertical"
    android:padding="16dp">

    <TextView
        android:id="@+id/status"
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:text="Hazır"
        android:textSize="16sp"
        android:paddingBottom="8dp" />

    <LinearLayout
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:orientation="horizontal">

        <Button
            android:id="@+id/btnScan"
            android:layout_width="0dp"
            android:layout_height="wrap_content"
            android:layout_weight="1"
            android:text="Kumandayı ara" />

        <Button
            android:id="@+id/btnAccess"
            android:layout_width="0dp"
            android:layout_height="wrap_content"
            android:layout_weight="1"
            android:text="Genel tuş işleme" />
    </LinearLayout>

    <androidx.appcompat.widget.SwitchCompat
        android:id="@+id/switchFilter"
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:checked="true"
        android:text="Sadece Fire/Amazon/Alexa kumandaları" />

    <ListView
        android:id="@+id/deviceList"
        android:layout_width="match_parent"
        android:layout_height="0dp"
        android:layout_weight="1" />

    <TextView
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:paddingTop="8dp"
        android:text="Tuş günlüğü"
        android:textStyle="bold" />

    <ScrollView
        android:layout_width="match_parent"
        android:layout_height="0dp"
        android:layout_weight="1">

        <TextView
            android:id="@+id/log"
            android:layout_width="match_parent"
            android:layout_height="wrap_content"
            android:fontFamily="monospace"
            android:textSize="13sp" />
    </ScrollView>
</LinearLayout>
END_OF_FILE_XYZ
mkdir -p 'app/src/main/res/values'
cat > 'app/src/main/res/values/strings.xml' <<'END_OF_FILE_XYZ'
<resources>
    <string name="app_name">Fire Kumanda</string>
    <string name="service_label">Fire Kumanda Tuş İşleme</string>
    <string name="service_desc">Amazon Fire kumandasının tuşlarını algılar ve cihazda eylemlere dönüştürür.</string>
</resources>
END_OF_FILE_XYZ
mkdir -p 'app/src/main/res/xml'
cat > 'app/src/main/res/xml/accessibility_service_config.xml' <<'END_OF_FILE_XYZ'
<?xml version="1.0" encoding="utf-8"?>
<accessibility-service xmlns:android="http://schemas.android.com/apk/res/android"
    android:accessibilityEventTypes="typeWindowStateChanged"
    android:accessibilityFeedbackType="feedbackGeneric"
    android:accessibilityFlags="flagRequestFilterKeyEvents"
    android:canRequestFilterKeyEvents="true"
    android:description="@string/service_desc"
    android:notificationTimeout="100" />
END_OF_FILE_XYZ
cat > 'build.gradle.kts' <<'END_OF_FILE_XYZ'
plugins {
    id("com.android.application") version "8.5.2" apply false
    id("org.jetbrains.kotlin.android") version "1.9.24" apply false
}
END_OF_FILE_XYZ
cat > 'gradle.properties' <<'END_OF_FILE_XYZ'
org.gradle.jvmargs=-Xmx2048m -Dfile.encoding=UTF-8
android.useAndroidX=true
kotlin.code.style=official
END_OF_FILE_XYZ
cat > 'settings.gradle.kts' <<'END_OF_FILE_XYZ'
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}
rootProject.name = "FireRemoteApp"
include(":app")
END_OF_FILE_XYZ
