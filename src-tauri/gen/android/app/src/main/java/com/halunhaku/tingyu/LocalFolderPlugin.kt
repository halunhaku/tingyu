package com.halunhaku.tingyu

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import androidx.activity.result.ActivityResult
import app.tauri.annotation.ActivityCallback
import app.tauri.annotation.Command
import app.tauri.annotation.InvokeArg
import app.tauri.annotation.TauriPlugin
import app.tauri.plugin.Invoke
import app.tauri.plugin.Plugin
import java.util.ArrayDeque

private const val MAX_SCAN_DEPTH = 8
private const val MAX_SCAN_ENTRIES = 5_000

@InvokeArg
class ScanFolderArgs {
  lateinit var rootUri: String
}

data class PickedFolder(
  val uri: String,
  val name: String,
)

data class LocalAudioFile(
  val uri: String,
  val name: String,
  val album: String,
  val size: Long,
  val modified: Long,
)

data class LocalFolderScan(
  val name: String,
  val files: List<LocalAudioFile>,
)

private data class PendingDirectory(
  val documentId: String,
  val name: String,
  val depth: Int,
)

@TauriPlugin
class LocalFolderPlugin(private val activity: Activity) : Plugin(activity) {
  @Command
  fun pickFolder(invoke: Invoke) {
    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
      addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
      addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
      addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
    }
    startActivityForResult(invoke, intent, "folderPickerResult")
  }

  @ActivityCallback
  fun folderPickerResult(invoke: Invoke, result: ActivityResult) {
    if (result.resultCode == Activity.RESULT_CANCELED) {
      invoke.resolve()
      return
    }
    val uri = result.data?.data
    if (result.resultCode != Activity.RESULT_OK || uri == null) {
      invoke.reject("未能读取所选文件夹")
      return
    }

    try {
      activity.contentResolver.takePersistableUriPermission(
        uri,
        Intent.FLAG_GRANT_READ_URI_PERMISSION,
      )
      invoke.resolveObject(PickedFolder(uri.toString(), folderName(uri)))
    } catch (error: Exception) {
      invoke.reject(error.message ?: "无法保存文件夹访问权限")
    }
  }

  @Command
  fun scanFolder(invoke: Invoke) {
    val args = try {
      invoke.parseArgs(ScanFolderArgs::class.java)
    } catch (error: Exception) {
      invoke.reject(error.message ?: "文件夹参数无效")
      return
    }

    Thread {
      try {
        val rootUri = Uri.parse(args.rootUri)
        val rootId = DocumentsContract.getTreeDocumentId(rootUri)
        val files = mutableListOf<LocalAudioFile>()
        val directories = ArrayDeque<PendingDirectory>()
        directories.add(PendingDirectory(rootId, folderName(rootUri), 0))

        while (directories.isNotEmpty()) {
          val directory = directories.removeFirst()
          val childrenUri =
            DocumentsContract.buildChildDocumentsUriUsingTree(rootUri, directory.documentId)
          val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
          )

          activity.contentResolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
            val idColumn =
              cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameColumn =
              cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            val mimeColumn =
              cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE)
            val sizeColumn =
              cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_SIZE)
            val modifiedColumn =
              cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_LAST_MODIFIED)

            while (cursor.moveToNext()) {
              val id = cursor.getString(idColumn)
              val name = cursor.getString(nameColumn) ?: continue
              val mimeType = cursor.getString(mimeColumn)
              if (mimeType == DocumentsContract.Document.MIME_TYPE_DIR) {
                if (directory.depth < MAX_SCAN_DEPTH) {
                  directories.add(PendingDirectory(id, name, directory.depth + 1))
                }
                continue
              }
              if (!isAudioFile(name)) continue
              if (files.size >= MAX_SCAN_ENTRIES) {
                throw IllegalStateException("本地曲库超过 $MAX_SCAN_ENTRIES 首，已停止扫描")
              }
              val documentUri = DocumentsContract.buildDocumentUriUsingTree(rootUri, id)
              files.add(
                LocalAudioFile(
                  uri = documentUri.toString(),
                  name = name,
                  album = directory.name,
                  size = if (cursor.isNull(sizeColumn)) 0 else cursor.getLong(sizeColumn),
                  modified =
                    if (cursor.isNull(modifiedColumn)) 0 else cursor.getLong(modifiedColumn),
                ),
              )
            }
          }
        }

        files.sortBy { it.uri }
        invoke.resolveObject(LocalFolderScan(folderName(rootUri), files))
      } catch (error: Exception) {
        invoke.reject(error.message ?: "扫描 Android 本地曲库失败")
      }
    }.start()
  }

  private fun folderName(uri: Uri): String {
    val documentUri = DocumentsContract.buildDocumentUriUsingTree(
      uri,
      DocumentsContract.getTreeDocumentId(uri),
    )
    val projection = arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
    return activity.contentResolver.query(documentUri, projection, null, null, null)?.use { cursor ->
      if (cursor.moveToFirst()) cursor.getString(0) else null
    } ?: "本地音乐"
  }

  private fun isAudioFile(name: String): Boolean {
    return when (name.substringAfterLast('.', "").lowercase()) {
      "mp3", "flac", "m4a", "aac", "wav", "ogg", "opus" -> true
      else -> false
    }
  }
}
