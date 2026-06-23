package com.kiddulu.merge_count

import android.content.ActivityNotFoundException
import android.content.Intent
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "connect_merge/facebook_share"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "shareImage") {
                    val bytes = call.argument<ByteArray>("bytes")
                    if (bytes == null) {
                        result.success(false)
                    } else {
                        result.success(shareToFacebook(bytes))
                    }
                } else {
                    result.notImplemented()
                }
            }
    }

    /** Write the PNG and hand it to the Facebook app. Returns false if FB is
     *  not installed so Dart can fall back to the OS share sheet. */
    private fun shareToFacebook(bytes: ByteArray): Boolean {
        return try {
            val dir = File(cacheDir, "shared").apply { mkdirs() }
            val file = File(dir, "score.png")
            file.writeBytes(bytes)
            val uri = FileProvider.getUriForFile(
                this, "$packageName.fileprovider", file
            )
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = "image/png"
                putExtra(Intent.EXTRA_STREAM, uri)
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
