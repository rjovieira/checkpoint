package dev.checkpoint.checkpoint

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.FileNotFoundException
import java.util.concurrent.Executors

/**
 * The single Android bridge for Checkpoint.
 *
 * Everything platform-specific lives here and in [SafStorage]; the Dart side
 * sees only the ports it declares. Keeping the surface this small is what makes
 * an iOS implementation a matter of writing one more adapter rather than
 * reworking the app.
 */
class MainActivity : FlutterActivity() {

    private lateinit var storage: SafStorage
    private lateinit var channel: MethodChannel

    /**
     * SAF calls hit a content provider and can block for a long time on a large
     * folder, so they never run on the platform thread.
     */
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    private var pendingPickResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        storage = SafStorage(applicationContext)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result -> dispatch(call, result) }
    }

    override fun onDestroy() {
        io.shutdown()
        super.onDestroy()
    }

    private fun dispatch(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // Runs on the platform thread because it must start an activity.
            "pickDirectory" -> pickDirectory(call, result)
            else -> runInBackground(call, result)
        }
    }

    private fun runInBackground(call: MethodCall, result: MethodChannel.Result) {
        io.execute {
            try {
                // Void-returning handlers yield kotlin.Unit, which the standard
                // message codec cannot encode — send null instead.
                val value = handle(call).takeUnless { it is Unit }
                main.post { result.success(value) }
            } catch (e: SafStorage.AccessDeniedException) {
                main.post { result.error(ERROR_ACCESS_DENIED, e.message, null) }
            } catch (e: SecurityException) {
                main.post { result.error(ERROR_ACCESS_DENIED, e.message, null) }
            } catch (e: FileNotFoundException) {
                main.post { result.error(ERROR_NOT_FOUND, e.message, null) }
            } catch (e: Exception) {
                main.post { result.error(ERROR_IO, e.message, null) }
            }
        }
    }

    private fun handle(call: MethodCall): Any? = when (call.method) {
        "findInstalledPackages" -> findInstalledPackages(call.arg("packageIds"))
        "releaseRoot" -> storage.releaseGrant(call.arg("rootId"))
        "isAccessible" -> storage.isAccessible(call.arg("rootId"))
        "listDirectory" -> storage.listDirectory(call.arg("rootId"), call.argument("path"))
        "listFilesRecursively" ->
            storage.listFilesRecursively(call.arg("rootId"), call.argument("path"))
        "stat" -> storage.stat(call.arg("rootId"), call.arg("path"))
        "exists" -> storage.exists(call.arg("rootId"), call.arg("path"))
        "readFile" -> storage.readFile(call.arg("rootId"), call.arg("path"))
        "writeFile" ->
            storage.writeFile(call.arg("rootId"), call.arg("path"), call.arg("bytes"))
        "createDirectory" -> storage.createDirectory(call.arg("rootId"), call.arg("path"))
        "delete" -> storage.delete(call.arg("rootId"), call.arg("path"))
        else -> throw UnsupportedOperationException("Unknown method ${call.method}")
    }

    /**
     * Answers only about the packages Checkpoint asks for, which are declared in
     * `<queries>` in the manifest. This is deliberately not
     * `getInstalledApplications`: enumerating the user's apps would require the
     * `QUERY_ALL_PACKAGES` permission, which Checkpoint does not need and does
     * not request.
     */
    private fun findInstalledPackages(packageIds: List<String>): List<Map<String, String>> {
        val packageManager = packageManager
        val found = mutableListOf<Map<String, String>>()
        for (packageId in packageIds) {
            try {
                val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    packageManager.getApplicationInfo(
                        packageId,
                        PackageManager.ApplicationInfoFlags.of(0),
                    )
                } else {
                    @Suppress("DEPRECATION")
                    packageManager.getApplicationInfo(packageId, 0)
                }
                found.add(
                    mapOf(
                        "packageId" to packageId,
                        "label" to packageManager.getApplicationLabel(info).toString(),
                    ),
                )
            } catch (_: PackageManager.NameNotFoundException) {
                // Not installed, or not visible to us. Either way: skip.
            }
        }
        return found
    }

    private fun pickDirectory(call: MethodCall, result: MethodChannel.Result) {
        if (pendingPickResult != null) {
            result.error(ERROR_IO, "A folder is already being selected", null)
            return
        }
        pendingPickResult = result

        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
            )
            // Opens the picker near the folder we expect. Purely a convenience:
            // the user can still choose anywhere, and the app must cope.
            val hint: String? = call.argument("initialLocationHint")
            if (hint != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                putExtra(DocumentsContract.EXTRA_INITIAL_URI, Uri.parse(hint))
            }
        }

        try {
            startActivityForResult(intent, REQUEST_PICK_DIRECTORY)
        } catch (e: Exception) {
            pendingPickResult = null
            result.error(ERROR_IO, "No folder picker is available", e.message)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQUEST_PICK_DIRECTORY) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }

        val result = pendingPickResult
        pendingPickResult = null
        if (result == null) return

        val treeUri = data?.data
        if (resultCode != Activity.RESULT_OK || treeUri == null) {
            // Cancelling is an ordinary outcome, not an error.
            result.success(null)
            return
        }

        try {
            storage.persistGrant(treeUri)
            result.success(
                mapOf(
                    "rootId" to treeUri.toString(),
                    "displayName" to storage.displayNameOf(treeUri),
                    "displayPath" to storage.displayPathOf(treeUri),
                ),
            )
        } catch (e: Exception) {
            result.error(ERROR_ACCESS_DENIED, "Could not keep access to this folder", e.message)
        }
    }

    private inline fun <reified T> MethodCall.arg(name: String): T =
        argument<T>(name) ?: throw IllegalArgumentException("Missing argument '$name'")

    private companion object {
        const val CHANNEL = "dev.checkpoint/storage"
        const val REQUEST_PICK_DIRECTORY = 0x0C4D

        const val ERROR_ACCESS_DENIED = "access_denied"
        const val ERROR_NOT_FOUND = "not_found"
        const val ERROR_IO = "io_error"
    }
}
