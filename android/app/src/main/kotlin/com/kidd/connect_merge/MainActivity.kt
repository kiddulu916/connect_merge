package com.kidd.connect_merge

import android.content.ActivityNotFoundException
import android.content.Intent
import android.os.Bundle
import android.util.Log
import androidx.core.content.FileProvider
import com.google.android.ump.ConsentInformation
import com.google.android.ump.UserMessagingPlatform
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val facebookShareChannel = "connect_merge/facebook_share"
    private val consentChannel = "connect_merge/consent"
    private val TAG = "ConnectMergeMainActivity"

    private lateinit var consentInformation: ConsentInformation

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.d(TAG, "onCreate: intent=${intent?.data}")
        consentInformation = UserMessagingPlatform.getConsentInformation(this)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        Log.d(TAG, "onNewIntent: intent=${intent.data}")
        setIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, facebookShareChannel)
            .setMethodCallHandler { call, result ->
                if (call.method == "shareImage") {
                    val bytes = call.argument<ByteArray>("bytes")
                    val text = call.argument<String>("text")
                    result.success(if (bytes != null) shareToFacebook(bytes, text) else false)
                } else {
                    result.notImplemented()
                }
            }

        // Consent bridge — lets Dart gate ad requests and surface a privacy options entry point.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, consentChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canRequestAds" ->
                        result.success(consentInformation.canRequestAds())

                    "isPrivacyOptionsRequired" ->
                        result.success(
                            consentInformation.privacyOptionsRequirementStatus ==
                                ConsentInformation.PrivacyOptionsRequirementStatus.REQUIRED
                        )

                    "showPrivacyOptionsForm" ->
                        UserMessagingPlatform.showPrivacyOptionsForm(this) { formError ->
                            if (formError != null) {
                                result.error("UMP_ERROR", formError.message, null)
                            } else {
                                result.success(null)
                            }
                        }

                    else -> result.notImplemented()
                }
            }
    }

    private fun shareToFacebook(bytes: ByteArray, text: String?): Boolean {
        return try {
            val dir = File(cacheDir, "shared").apply { mkdirs() }
            val file = File(dir, "score.png")
            file.writeBytes(bytes)
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = "image/png"
                putExtra(Intent.EXTRA_STREAM, uri)
                putExtra(Intent.EXTRA_TEXT, text)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                setPackage("com.facebook.katana")
            }
            startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            false
        } catch (e: Exception) {
            false
        }
    }
}
