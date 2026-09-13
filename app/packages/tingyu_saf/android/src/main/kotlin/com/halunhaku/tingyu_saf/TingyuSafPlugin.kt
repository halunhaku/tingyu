package com.halunhaku.tingyu_saf

import android.app.Activity
import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.PluginRegistry

/**
 * Android 的「本地音乐目录」桥：
 *
 * Android 10+ 无法直接读取 /sdcard 下的任意目录，必须走 SAF（Storage Access Framework）：
 * 1. `pickDirectory` 拉起系统的目录选择器，拿到 tree URI 并**持久化**读权限
 *    （重启后依然有效，角色等同于 iOS 的安全作用域书签）；
 * 2. `listChildren` 用 DocumentsContract 枚举目录内容，返回子项的 documentId /
 *    名称 / MIME / 大小 / 修改时间；子项 URI 由 Dart 侧用同一个 documentId 拼出，
 *    可直接交给 ExoPlayer 播放（`content://` 协议）。
 */
class TingyuSafPlugin : FlutterPlugin, MethodCallHandler, ActivityAware,
    PluginRegistry.ActivityResultListener {

    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var activity: Activity? = null
    private var pendingResult: MethodChannel.Result? = null

    override fun onAttachedToEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: MethodChannel.Result) {
        when (call.method) {
            "pickDirectory" -> pickDirectory(result)
            "listChildren" -> listChildren(call, result)
            "hasPermission" -> result.success(hasPersistedPermission(call.argument<String>("treeUri")))
            "releasePermission" -> releasePermission(call.argument<String>("treeUri"), result)
            "openInQuark" -> openInQuark(call.argument<String>("url"), result)
            "bringToForeground" -> bringToForeground(result)
            else -> result.notImplemented()
        }
    }

    private fun pickDirectory(result: MethodChannel.Result) {
        val current = activity
        if (current == null) {
            result.error("no_activity", "当前没有可用的 Activity", null)
            return
        }
        if (pendingResult != null) {
            result.error("busy", "已有一个目录选择正在进行", null)
            return
        }
        pendingResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        try {
            current.startActivityForResult(intent, REQUEST_PICK_DIRECTORY)
        } catch (error: Exception) {
            pendingResult = null
            result.error("picker_failed", error.message, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_PICK_DIRECTORY) {
            return false
        }
        val result = pendingResult ?: return true
        pendingResult = null

        val uri: Uri? = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null) // 用户取消
            return true
        }
        return try {
            context.contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION
            )
            result.success(uri.toString())
            true
        } catch (error: SecurityException) {
            result.error("persist_failed", error.message, null)
            false
        }
    }

    private fun listChildren(call: MethodCall, result: MethodChannel.Result) {
        val treeUri = call.argument<String>("treeUri")
        if (treeUri.isNullOrEmpty()) {
            result.error("bad_args", "缺少 treeUri", null)
            return
        }
        val parentDocumentId = call.argument<String>("parentDocumentId")
        try {
            val tree = Uri.parse(treeUri)
            val rootId = DocumentsContract.getTreeDocumentId(tree)
            val effectiveParentId = parentDocumentId?.takeIf { it.isNotEmpty() } ?: rootId
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, effectiveParentId)

            val projection = arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_SIZE,
                DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            )
            val entries = ArrayList<Map<String, Any?>>()
            context.contentResolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
                while (cursor.moveToNext()) {
                    val documentId = cursor.getString(0) ?: continue
                    val name = cursor.getString(1) ?: continue
                    val mime = cursor.getString(2) ?: ""
                    val size = if (cursor.isNull(3)) 0L else cursor.getLong(3)
                    val modified = if (cursor.isNull(4)) null else cursor.getLong(4)
                    // 直接给出可供 ExoPlayer 读取的 content:// URI，避免 Dart 侧重拼转义。
                    val childUri = DocumentsContract.buildDocumentUriUsingTree(tree, documentId)
                    entries.add(
                        mapOf(
                            "documentId" to documentId,
                            "uri" to childUri.toString(),
                            "name" to name,
                            "isDirectory" to (mime == DocumentsContract.Document.MIME_TYPE_DIR),
                            "mimeType" to mime,
                            "size" to size,
                            "lastModified" to modified,
                        )
                    )
                }
            }
            result.success(entries)
        } catch (error: SecurityException) {
            result.error("permission_denied", error.message, null)
        } catch (error: Exception) {
            result.error("list_failed", error.message, null)
        }
    }

    private fun hasPersistedPermission(treeUri: String?): Boolean {
        if (treeUri.isNullOrEmpty()) {
            return false
        }
        return context.contentResolver.persistedUriPermissions.any {
            it.isReadPermission && it.uri.toString() == treeUri
        }
    }

    private fun releasePermission(treeUri: String?, result: MethodChannel.Result) {
        if (treeUri.isNullOrEmpty()) {
            result.success(true)
            return
        }
        return try {
            context.contentResolver.releasePersistableUriPermission(
                Uri.parse(treeUri),
                Intent.FLAG_GRANT_READ_URI_PERMISSION
            )
            result.success(true)
        } catch (error: Exception) {
            result.error("release_failed", error.message, null)
        }
    }

    private fun openInQuark(url: String?, result: MethodChannel.Result) {
        if (url.isNullOrEmpty()) {
            result.success(false)
            return
        }
        val host = activity ?: context
        val packages = listOf("com.quark.clouddrive", "com.quark.browser")
        for (pkg in packages) {
            try {
                val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
                intent.setPackage(pkg)
                if (host !is Activity) {
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                if (intent.resolveActivity(host.packageManager) != null) {
                    host.startActivity(intent)
                    result.success(true)
                    return
                }
            } catch (_: Exception) {
            }
        }
        try {
            val fallback = Intent(Intent.ACTION_VIEW, Uri.parse(url))
            if (host !is Activity) {
                fallback.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            host.startActivity(fallback)
            result.success(true)
        } catch (_: Exception) {
            result.success(false)
        }
    }

    private fun bringToForeground(result: MethodChannel.Result) {
        var moved = false
        val current = activity
        if (current != null) {
            try {
                val am = current.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                am.moveTaskToFront(current.taskId, 0)
                moved = true
            } catch (_: Exception) {
            }
        }
        try {
            val launch = launchIntent()
            if (launch != null) {
                context.startActivity(launch)
                moved = true
            }
        } catch (_: Exception) {
        }
        postReturnNotification()
        result.success(moved)
    }

    private fun launchIntent(): Intent? {
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return null
        launch.addFlags(
            Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                Intent.FLAG_ACTIVITY_SINGLE_TOP,
        )
        return launch
    }

    private fun postReturnNotification() {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channelId = "tingyu.login"
        if (Build.VERSION.SDK_INT >= 26) {
            val channel = NotificationChannel(
                channelId,
                "登录",
                NotificationManager.IMPORTANCE_HIGH,
            )
            channel.description = "夸克登录完成后返回听屿"
            manager.createNotificationChannel(channel)
        }
        val launch = launchIntent() ?: return
        val pending = PendingIntent.getActivity(
            context,
            RETURN_NOTIFY_ID,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(context, channelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        val notification = builder
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("听屿")
            .setContentText("夸克已登录，点这里选择文件夹")
            .setContentIntent(pending)
            .setAutoCancel(true)
            .build()
        manager.notify(RETURN_NOTIFY_ID, notification)
    }

    private companion object {
        const val CHANNEL = "tingyu/saf"
        const val REQUEST_PICK_DIRECTORY = 0x5AF1
        const val RETURN_NOTIFY_ID = 0x71
    }
}
