package dev.checkpoint.checkpoint

import android.content.ContentResolver
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.provider.DocumentsContract
import java.io.FileNotFoundException

/**
 * Storage Access Framework operations addressed as (tree URI, relative path).
 *
 * Checkpoint never asks for broad storage permissions. Every byte read or
 * written goes through a tree the user explicitly granted, which is what makes
 * `MANAGE_EXTERNAL_STORAGE` unnecessary.
 *
 * Paths arriving here have already been validated on the Dart side (see
 * `SafePath`): they are relative, and contain no `..` or empty components. This
 * class resolves them one component at a time against the granted tree, so
 * there is no string concatenation that could escape it even if that guarantee
 * were ever weakened.
 */
class SafStorage(private val context: Context) {

    class AccessDeniedException(message: String) : Exception(message)

    private val resolver: ContentResolver get() = context.contentResolver

    private data class Entry(
        val documentId: String,
        val displayName: String,
        val mimeType: String,
        val size: Long,
        val lastModified: Long,
    ) {
        val isDirectory: Boolean get() = mimeType == DocumentsContract.Document.MIME_TYPE_DIR
    }

    private val projection = arrayOf(
        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
        // COLUMN_DISPLAY_NAME is queried directly rather than going through
        // DocumentFile.getName(), which appends a MIME-derived extension to
        // extension-less files and would silently rename saves like "file0" to
        // "file0.bin" on the way into a backup.
        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        DocumentsContract.Document.COLUMN_MIME_TYPE,
        DocumentsContract.Document.COLUMN_SIZE,
        DocumentsContract.Document.COLUMN_LAST_MODIFIED,
    )

    // ── grants ────────────────────────────────────────────────────────────

    fun persistGrant(treeUri: Uri) {
        resolver.takePersistableUriPermission(
            treeUri,
            android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION or
                android.content.Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
        )
    }

    fun releaseGrant(rootId: String) {
        val uri = Uri.parse(rootId)
        runCatching {
            resolver.releasePersistableUriPermission(
                uri,
                android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    android.content.Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        }
    }

    /** Whether the grant behind [rootId] still exists and still resolves. */
    fun isAccessible(rootId: String): Boolean {
        val uri = runCatching { Uri.parse(rootId) }.getOrNull() ?: return false
        val held = resolver.persistedUriPermissions.any {
            it.uri == uri && it.isReadPermission
        }
        if (!held) return false
        return runCatching { readEntry(uri, rootDocumentId(uri)) }.getOrNull() != null
    }

    /** A best-effort human-readable rendering of a tree URI, for display only. */
    fun displayPathOf(treeUri: Uri): String {
        val documentId = rootDocumentId(treeUri)
        val parts = documentId.split(':', limit = 2)
        val volume = when (parts.getOrNull(0)) {
            "primary" -> "Internal storage"
            else -> parts.getOrNull(0).orEmpty()
        }
        val path = parts.getOrNull(1).orEmpty()
        return if (path.isEmpty()) volume else "$volume/$path"
    }

    fun displayNameOf(treeUri: Uri): String {
        val documentId = rootDocumentId(treeUri)
        val leaf = documentId.substringAfterLast(':').substringAfterLast('/')
        return leaf.ifEmpty { "Selected folder" }
    }

    // ── reading ───────────────────────────────────────────────────────────

    fun listDirectory(rootId: String, relativePath: String?): List<Map<String, Any?>> {
        val treeUri = Uri.parse(rootId)
        val parentId = resolveDocumentId(treeUri, relativePath)
            ?: throw FileNotFoundException("No such directory: ${relativePath.orEmpty()}")

        val prefix = if (relativePath.isNullOrEmpty()) "" else "$relativePath/"
        return listChildren(treeUri, parentId).map { child ->
            mapOf(
                "path" to prefix + child.displayName,
                "isDirectory" to child.isDirectory,
                "size" to if (child.isDirectory) 0L else child.size,
                "modified" to child.lastModified,
            )
        }
    }

    fun listFilesRecursively(rootId: String, relativePath: String?): List<Map<String, Any?>> {
        val treeUri = Uri.parse(rootId)
        val startId = resolveDocumentId(treeUri, relativePath)
            ?: throw FileNotFoundException("No such directory: ${relativePath.orEmpty()}")

        val files = mutableListOf<Map<String, Any?>>()
        val pending = ArrayDeque<Pair<String, String>>()
        pending.add(startId to if (relativePath.isNullOrEmpty()) "" else "$relativePath/")

        // Bounded so a pathological or looping provider cannot spin forever.
        var visited = 0
        while (pending.isNotEmpty() && visited < MAX_ENTRIES_SCANNED) {
            val (documentId, prefix) = pending.removeFirst()
            for (child in listChildren(treeUri, documentId)) {
                visited++
                val childPath = prefix + child.displayName
                if (child.isDirectory) {
                    pending.add(child.documentId to "$childPath/")
                } else {
                    files.add(
                        mapOf(
                            "path" to childPath,
                            "isDirectory" to false,
                            "size" to child.size,
                            "modified" to child.lastModified,
                        ),
                    )
                }
            }
        }
        return files
    }

    fun stat(rootId: String, relativePath: String): Map<String, Any?>? {
        val treeUri = Uri.parse(rootId)
        val documentId = resolveDocumentId(treeUri, relativePath) ?: return null
        val entry = readEntry(treeUri, documentId) ?: return null
        return mapOf(
            "path" to relativePath,
            "isDirectory" to entry.isDirectory,
            "size" to if (entry.isDirectory) 0L else entry.size,
            "modified" to entry.lastModified,
        )
    }

    fun exists(rootId: String, relativePath: String): Boolean =
        resolveDocumentId(Uri.parse(rootId), relativePath) != null

    fun readFile(rootId: String, relativePath: String): ByteArray {
        val treeUri = Uri.parse(rootId)
        val documentId = resolveDocumentId(treeUri, relativePath)
            ?: throw FileNotFoundException("No such file: $relativePath")
        val uri = DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId)
        return resolver.openInputStream(uri)?.use { it.readBytes() }
            ?: throw FileNotFoundException("Cannot open $relativePath")
    }

    // ── writing ───────────────────────────────────────────────────────────

    fun writeFile(rootId: String, relativePath: String, bytes: ByteArray) {
        val treeUri = Uri.parse(rootId)
        val segments = relativePath.split('/')
        val name = segments.last()
        val parentId = createDirectories(treeUri, segments.dropLast(1))

        val existing = findChild(treeUri, parentId, name)
        val documentId = existing?.documentId ?: createFile(treeUri, parentId, name)
        val uri = DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId)

        // "wt" truncates, so a shorter file does not leave a tail of the old one
        // behind — which would corrupt a save in a way that is hard to notice.
        resolver.openOutputStream(uri, "wt")?.use { it.write(bytes) }
            ?: throw FileNotFoundException("Cannot write $relativePath")
    }

    fun createDirectory(rootId: String, relativePath: String) {
        val treeUri = Uri.parse(rootId)
        createDirectories(treeUri, relativePath.split('/'))
    }

    fun delete(rootId: String, relativePath: String) {
        val treeUri = Uri.parse(rootId)
        val documentId = resolveDocumentId(treeUri, relativePath) ?: return
        val uri = DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId)
        DocumentsContract.deleteDocument(resolver, uri)
    }

    // ── internals ─────────────────────────────────────────────────────────

    private fun rootDocumentId(treeUri: Uri): String =
        DocumentsContract.getTreeDocumentId(treeUri)

    /**
     * Walks [relativePath] one component at a time from the tree root.
     *
     * Resolution is by exact display name, so a component never becomes part of
     * a document id or a URI string — the granted tree stays the boundary.
     */
    private fun resolveDocumentId(treeUri: Uri, relativePath: String?): String? {
        var documentId = rootDocumentId(treeUri)
        if (relativePath.isNullOrEmpty()) return documentId
        for (segment in relativePath.split('/')) {
            if (segment.isEmpty() || segment == "." || segment == "..") return null
            documentId = findChild(treeUri, documentId, segment)?.documentId ?: return null
        }
        return documentId
    }

    private fun createDirectories(treeUri: Uri, segments: List<String>): String {
        var documentId = rootDocumentId(treeUri)
        for (segment in segments) {
            if (segment.isEmpty()) continue
            val existing = findChild(treeUri, documentId, segment)
            documentId = when {
                existing == null -> createDocument(
                    treeUri,
                    documentId,
                    DocumentsContract.Document.MIME_TYPE_DIR,
                    segment,
                )
                existing.isDirectory -> existing.documentId
                else -> throw AccessDeniedException(
                    "A file named '$segment' is in the way",
                )
            }
        }
        return documentId
    }

    private fun createFile(treeUri: Uri, parentId: String, name: String): String =
        // A generic binary MIME type keeps providers from inventing an
        // extension for save files that legitimately have none.
        createDocument(treeUri, parentId, "application/octet-stream", name)

    private fun createDocument(
        treeUri: Uri,
        parentId: String,
        mimeType: String,
        name: String,
    ): String {
        val parentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, parentId)
        val created = DocumentsContract.createDocument(resolver, parentUri, mimeType, name)
            ?: throw AccessDeniedException("Cannot create '$name'")
        return DocumentsContract.getDocumentId(created)
    }

    private fun findChild(treeUri: Uri, parentId: String, name: String): Entry? =
        listChildren(treeUri, parentId).firstOrNull { it.displayName == name }

    private fun listChildren(treeUri: Uri, parentId: String): List<Entry> {
        val childrenUri =
            DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentId)
        val entries = mutableListOf<Entry>()
        queryOrThrow(childrenUri)?.use { cursor ->
            while (cursor.moveToNext()) {
                entries.add(cursor.toEntry() ?: continue)
            }
        }
        return entries
    }

    private fun readEntry(treeUri: Uri, documentId: String): Entry? {
        val uri = DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId)
        return queryOrThrow(uri)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.toEntry() else null
        }
    }

    private fun queryOrThrow(uri: Uri): Cursor? = try {
        resolver.query(uri, projection, null, null, null)
    } catch (e: SecurityException) {
        throw AccessDeniedException(e.message ?: "Access to this folder was revoked")
    }

    private fun Cursor.toEntry(): Entry? {
        val documentId = getString(0) ?: return null
        val displayName = getString(1) ?: return null
        return Entry(
            documentId = documentId,
            displayName = displayName,
            mimeType = getString(2).orEmpty(),
            size = if (isNull(3)) 0L else getLong(3),
            lastModified = if (isNull(4)) 0L else getLong(4),
        )
    }

    private companion object {
        /** Guards against a provider that reports a cyclic or unbounded tree. */
        const val MAX_ENTRIES_SCANNED = 200_000
    }
}
