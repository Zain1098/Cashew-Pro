package com.budget.tracker_app

import android.app.Activity
import android.app.DownloadManager
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.IOException

class MainActivity : FlutterFragmentActivity() {
    companion object {
        private const val CHANNEL = "com.budget.tracker_app/native_files"
        private const val SAVE_FILE_REQUEST_CODE = 49021
    }

    private var pendingSaveResult: MethodChannel.Result? = null
    private var pendingSaveBytes: ByteArray? = null
    private var pendingSaveFileName: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveFile" -> {
                        if (pendingSaveResult != null) {
                            result.error("BUSY", "Another file save operation is already in progress.", null)
                            return@setMethodCallHandler
                        }
                        val fileName = call.argument<String>("fileName") ?: "export"
                        val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
                        val bytes = call.argument<ByteArray>("bytes")
                        if (bytes == null) {
                            result.error("INVALID_ARGS", "File bytes cannot be null.", null)
                            return@setMethodCallHandler
                        }
                        pendingSaveResult = result
                        pendingSaveBytes = bytes
                        pendingSaveFileName = fileName

                        try {
                            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = mimeType
                                putExtra(Intent.EXTRA_TITLE, fileName)
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                    val downloadsUri = Uri.parse(
                                        "content://com.android.externalstorage.documents/document/primary%3ADownload"
                                    )
                                    putExtra(DocumentsContract.EXTRA_INITIAL_URI, downloadsUri)
                                }
                            }
                            @Suppress("DEPRECATION")
                            startActivityForResult(intent, SAVE_FILE_REQUEST_CODE)
                        } catch (e: Exception) {
                            pendingSaveResult = null
                            pendingSaveBytes = null
                            pendingSaveFileName = null
                            result.error("INTENT_FAILED", e.message ?: e.toString(), null)
                        }
                    }

                    "openFile" -> {
                        val uriString = call.argument<String>("uri")
                        val mimeType = call.argument<String>("mimeType") ?: "*/*"
                        if (uriString.isNullOrEmpty()) {
                            result.error("INVALID_ARGS", "URI cannot be empty.", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val parsedUri = Uri.parse(uriString)
                            val viewIntent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(parsedUri, mimeType)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(viewIntent)
                            result.success(mapOf("opened" to true, "openedDownloads" to false))
                        } catch (_: ActivityNotFoundException) {
                            try {
                                val downloadsIntent = Intent(DownloadManager.ACTION_VIEW_DOWNLOADS).apply {
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                }
                                startActivity(downloadsIntent)
                                result.success(mapOf("opened" to true, "openedDownloads" to true))
                            } catch (e2: Exception) {
                                result.error("OPEN_FAILED", e2.message ?: e2.toString(), null)
                            }
                        } catch (e: Exception) {
                            result.error("OPEN_FAILED", e.message ?: e.toString(), null)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != SAVE_FILE_REQUEST_CODE) return

        val callback = pendingSaveResult
        val bytes = pendingSaveBytes
        val fallbackName = pendingSaveFileName ?: "export"
        pendingSaveResult = null
        pendingSaveBytes = null
        pendingSaveFileName = null

        if (callback == null) return

        if (resultCode != Activity.RESULT_OK || data?.data == null || bytes == null) {
            callback.success(mapOf("saved" to false, "cancelled" to true))
            return
        }

        val targetUri: Uri = data.data!!
        try {
            val outStream = contentResolver.openOutputStream(targetUri)
                ?: throw IOException("Unable to open destination output stream.")
            outStream.use { stream ->
                stream.write(bytes)
                stream.flush()
            }
            var displayName = fallbackName
            contentResolver.query(
                targetUri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0 && !cursor.isNull(idx)) {
                        displayName = cursor.getString(idx)
                    }
                }
            }
            callback.success(
                mapOf(
                    "saved" to true,
                    "cancelled" to false,
                    "uri" to targetUri.toString(),
                    "displayName" to displayName
                )
            )
        } catch (e: Exception) {
            callback.error("WRITE_FAILED", e.message ?: e.toString(), null)
        }
    }
}
