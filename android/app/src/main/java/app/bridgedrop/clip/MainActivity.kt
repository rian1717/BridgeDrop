package app.bridgedrop.clip

import android.Manifest
import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.graphics.Color
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.app.AlertDialog
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import android.widget.Button
import android.widget.EditText
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast

class MainActivity : Activity() {
    private lateinit var status: TextView
    private lateinit var next: TextView
    private lateinit var pairSection: View
    private lateinit var pairAgain: Button
    private lateinit var removeMac: Button
    private lateinit var accessButton: Button
    private lateinit var accessHelp: TextView
    private lateinit var backgroundButton: Button
    private lateinit var backgroundHelp: TextView
    private var showPairing = false
    private var looking = false

    override fun onCreate(savedInstanceState: Bundle?) {
        installSplashScreen()
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        status = findViewById(R.id.status)
        next = findViewById(R.id.next)
        pairSection = findViewById(R.id.pair_section)
        pairAgain = findViewById(R.id.pair_again)
        removeMac = findViewById(R.id.remove_mac)
        accessButton = findViewById(R.id.access)
        accessHelp = findViewById(R.id.access_help)
        backgroundButton = findViewById(R.id.background)
        backgroundHelp = findViewById(R.id.background_help)

        findViewById<Button>(R.id.pair_link).setOnClickListener {
            ClipSync.pairWithLink(this, findViewById<EditText>(R.id.link).text.toString()) {
                show(it)
                if (ClipSync.isPaired(this)) showPairing = false
            }
        }
        findViewById<Button>(R.id.find).setOnClickListener { findMacs(announce = true) }
        pairAgain.setOnClickListener {
            showPairing = true
            refresh()
            findMacs(announce = true)
        }
        removeMac.setOnClickListener { confirmRemoveMac() }
        ClipSync.onRemoved = { refresh() }
        accessButton.setOnClickListener { openClipboardAccess() }
        backgroundButton.setOnClickListener { openBackgroundSettings() }
        findViewById<Button>(R.id.photo_new).setOnClickListener {
            PhotoWeb.newLink()
            refreshPhoto()
            show("New link. Scan the code again.")
        }
        findViewById<Button>(R.id.photo_send).setOnClickListener { pickPhotos() }
        if (Build.VERSION.SDK_INT >= 33) {
            val needed = listOf(
                Manifest.permission.POST_NOTIFICATIONS,
                Manifest.permission.NEARBY_WIFI_DEVICES,
            ).filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
            if (needed.isNotEmpty()) requestPermissions(needed.toTypedArray(), 1)
        }
        consumeLink(intent)
        refresh()
    }

    override fun onResume() {
        super.onResume()
        refresh()
        PhotoWeb.start(this)
        ClipForegroundService.start(this)
        ClipSync.onRemoved = {
            showPairing = false
            show("Removed on the Mac")
            refresh()
        }
        ClipSync.startWatch(this)
        if (!ClipSync.isPaired(this) || showPairing) findMacs(announce = false)
        if (ClipSync.isPaired(this)) {
            if (accessibilityOn()) {
                ClipSync.sendCurrent(this) { message ->
                    if (message.startsWith("Sent") || message.startsWith("The Mac")) show(message)
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        consumeLink(intent)
    }

    private fun consumeLink(intent: Intent?) {
        val data = intent?.data ?: return
        if (data.scheme != "bridgedrop") return
        ClipSync.pairWithLink(this, data.toString()) {
            show(it)
            if (ClipSync.isPaired(this)) showPairing = false
        }
    }

    private fun findMacs(announce: Boolean) {
        if (looking) return
        looking = true
        val macs = findViewById<LinearLayout>(R.id.macs)
        macs.removeAllViews()
        if (announce) show("Looking for your Mac…")
        ClipSync.discover(this, found = { mac ->
            macs.addView(macRow(mac))
        }, finished = {
            looking = false
            if (announce && macs.childCount == 0) {
                show("No Mac found. On the Mac, turn on Paste phone copies here.")
            } else if (announce) {
                show("Tap your Mac.")
            }
        })
    }

    private fun macRow(mac: ClipSync.Mac): Button {
        val button = Button(this)
        button.text = mac.name
        button.isAllCaps = false
        button.textSize = 17f
        button.setTextColor(Color.parseColor("#1D2B40"))
        button.gravity = Gravity.START or Gravity.CENTER_VERTICAL
        button.background = getDrawable(R.drawable.bg_secondary)
        button.backgroundTintList = null
        button.stateListAnimator = null
        val pad = (18 * resources.displayMetrics.density).toInt()
        button.setPadding(pad, 0, pad, 0)
        val params = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            (56 * resources.displayMetrics.density).toInt(),
        )
        params.topMargin = (8 * resources.displayMetrics.density).toInt()
        button.layoutParams = params
        button.setOnClickListener {
            show("Pairing with ${mac.name}…")
            ClipSync.pairOnWifi(this, mac) {
                show(it)
                if (ClipSync.isPaired(this)) showPairing = false
            }
        }
        return button
    }

    private fun show(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_LONG).show()
        status.text = message
        if (ClipSync.isPaired(this)) keepAlive()
        updateChrome()
        status.text = message
    }

    private fun refresh() {
        updateChrome()
        refreshPhoto()
        if (ClipSync.isPaired(this)) keepAlive()
    }

    private fun refreshPhoto() {
        PhotoWeb.start(this)
        val link = PhotoWeb.link()
        findViewById<TextView>(R.id.photo_status).text = if (link.isEmpty()) {
            "Connect to Wi-Fi. The iPhone opens this in Safari."
        } else {
            "Point the iPhone camera here. Safari opens. Nothing to install."
        }
        findViewById<TextView>(R.id.photo_address).text = link
        findViewById<ImageView>(R.id.photo_qr).setImageBitmap(PhotoWeb.qr())
    }

    private fun pickPhotos() {
        if (PhotoWeb.link().isEmpty()) {
            show("Connect this phone to Wi-Fi first.")
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "image/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        startActivityForResult(intent, 7)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 7 || resultCode != RESULT_OK || data == null) return
        val uris = mutableListOf<Uri>()
        val clip = data.clipData
        if (clip != null) {
            for (index in 0 until clip.itemCount) uris.add(clip.getItemAt(index).uri)
        } else {
            data.data?.let { uris.add(it) }
        }
        show("Adding ${uris.size} photo${if (uris.size == 1) "" else "s"} for the iPhone…")
        PhotoWeb.add(this, uris) { show(it) }
    }

    private fun updateChrome() {
        val paired = ClipSync.isPaired(this)
        val access = accessibilityOn()
        val background = backgroundOpened()
        val showForm = !paired || showPairing
        val staleAccess = access && !getSharedPreferences("bridgedrop-clip", MODE_PRIVATE)
            .getBoolean("canReadScreen", true)

        pairSection.visibility = if (showForm) View.VISIBLE else View.GONE
        pairAgain.visibility = if (paired && !showPairing) View.VISIBLE else View.GONE
        removeMac.visibility = if (paired && !showPairing) View.VISIBLE else View.GONE
        accessButton.text = if (access) "Clipboard access is on" else "Turn on clipboard access"
        backgroundButton.text = if (background) {
            "Background settings opened"
        } else {
            "Allow this phone to keep BridgeDrop running"
        }
        accessHelp.text = if (access) {
            "On. A copy on this phone can paste on the Mac."
        } else {
            "Needed so a copy still leaves this phone when BridgeDrop is closed."
        }
        backgroundHelp.text = if (background) {
            "Set BridgeDrop to Unrestricted so it keeps running."
        } else {
            "Lets a copy reach the Mac after you leave this app."
        }
        status.text = when {
            !paired -> "Find your Mac"
            !access -> "Paired with ${ClipSync.pairedName(this)}"
            staleAccess -> "Paired with ${ClipSync.pairedName(this)}"
            else -> "Paired with ${ClipSync.pairedName(this)}"
        }
        next.text = when {
            !paired -> "Same Wi-Fi. Tap your Mac. No code to type."
            !access -> "Turn on clipboard access, then copy anywhere on this phone."
            staleAccess -> "Turn clipboard access off, then on again, once."
            else -> "This phone shows on the Mac while the screen is on."
        }
    }

    private fun confirmRemoveMac() {
        val name = ClipSync.pairedName(this)
        AlertDialog.Builder(this)
            .setTitle("Remove $name?")
            .setMessage("Copies on this phone will stop going to $name. You can pair again later.")
            .setNegativeButton("Cancel", null)
            .setPositiveButton("Remove") { _, _ ->
                ClipSync.leave(this) {
                    showPairing = false
                    show("Removed $name")
                    refresh()
                }
            }
            .show()
    }

    private fun keepAlive() {
        ClipForegroundService.start(this)
    }

    private fun accessibilityOn(): Boolean {
        val enabled = Settings.Secure.getString(contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES)
            ?: return false
        val name = ComponentName(this, ClipboardAccessibilityService::class.java).flattenToString()
        return enabled.split(':').any { it.equals(name, ignoreCase = true) }
    }

    private fun backgroundOpened(): Boolean {
        return getSharedPreferences("bridgedrop-clip", Context.MODE_PRIVATE)
            .getBoolean("backgroundOpened", false)
    }

    private fun openClipboardAccess() {
        if (accessibilityOn()) {
            show("Clipboard access is already on. Copy on this phone, then press ⌘V on the Mac.")
            return
        }
        val component = ComponentName(this, ClipboardAccessibilityService::class.java).flattenToString()
        val details = Intent("android.settings.ACCESSIBILITY_DETAILS_SETTINGS").apply {
            putExtra(Intent.EXTRA_COMPONENT_NAME, component)
            putExtra(":settings:fragment_args_key", component)
        }
        try {
            startActivity(details)
        } catch (_: Exception) {
            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
            Toast.makeText(
                this,
                "Open Downloaded apps, tap BridgeDrop, and switch it on.",
                Toast.LENGTH_LONG
            ).show()
        }
    }

    private fun openBackgroundSettings() {
        getSharedPreferences("bridgedrop-clip", Context.MODE_PRIVATE).edit()
            .putBoolean("backgroundOpened", true)
            .apply()
        val power = getSystemService(PowerManager::class.java)
        if (power != null && !power.isIgnoringBatteryOptimizations(packageName)) {
            try {
                startActivity(
                    Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                        .setData(Uri.parse("package:$packageName"))
                )
                refresh()
                return
            } catch (_: Exception) {
            }
        }
        val candidates = listOf(
            ComponentName("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity"),
            ComponentName("com.samsung.android.lool", "com.samsung.android.sm.battery.ui.BatteryActivity"),
            ComponentName("com.samsung.android.sm", "com.samsung.android.sm.battery.ui.BatteryActivity"),
        )
        for (component in candidates) {
            try {
                startActivity(Intent().setComponent(component))
                refresh()
                return
            } catch (_: Exception) {
            }
        }
        Toast.makeText(this, "Set BridgeDrop to Unrestricted in the phone’s battery settings.", Toast.LENGTH_LONG).show()
        startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).setData(
            android.net.Uri.parse("package:$packageName")
        ))
        refresh()
    }
}
