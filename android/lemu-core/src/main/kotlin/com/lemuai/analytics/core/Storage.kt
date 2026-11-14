package com.lemuai.analytics.core

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.OutputStreamWriter

/**
 * Where the SDK keeps its state: a few small values (anonymous id, user id, opt-out, last seen
 * app version) and the event queue, one JSON string per entry.
 *
 * Only the SDK's single worker thread calls these methods, except [getString] during setup.
 * Implementations may throw on I/O errors; the client catches and logs them.
 */
interface Storage {
    fun getString(key: String): String?

    fun putString(key: String, value: String)

    fun remove(key: String)

    /** Returns every queued entry in insertion order. */
    fun readQueue(): List<String>

    /** Appends one entry to the end of the queue. */
    fun appendQueue(entry: String)

    /** Replaces the whole queue. */
    fun writeQueue(entries: List<String>)

    /** True when nothing at all has been written. Used by tests and consent checks. */
    fun isEmpty(): Boolean
}

/** Keeps everything in memory. Used in tests and as a fallback when the disk is not usable. */
class InMemoryStorage : Storage {
    private val values = LinkedHashMap<String, String>()
    private val queue = ArrayList<String>()

    @Synchronized override fun getString(key: String): String? = values[key]

    @Synchronized override fun putString(key: String, value: String) {
        values[key] = value
    }

    @Synchronized override fun remove(key: String) {
        values.remove(key)
    }

    @Synchronized override fun readQueue(): List<String> = ArrayList(queue)

    @Synchronized override fun appendQueue(entry: String) {
        queue.add(entry)
    }

    @Synchronized override fun writeQueue(entries: List<String>) {
        queue.clear()
        queue.addAll(entries)
    }

    @Synchronized override fun isEmpty(): Boolean = values.isEmpty() && queue.isEmpty()
}

/**
 * File-backed storage: values in `lemu-values.json` (rewritten atomically), the queue in
 * `lemu-queue.jsonl` (one entry per line, appended on enqueue, rewritten after a send).
 * The directory is created on the first write, so nothing touches the disk before then.
 */
class FileStorage(private val directory: File) : Storage {
    private val valuesFile = File(directory, "lemu-values.json")
    private val queueFile = File(directory, "lemu-queue.jsonl")
    private var cache: LinkedHashMap<String, String>? = null

    @Synchronized override fun getString(key: String): String? = values()[key]

    @Synchronized override fun putString(key: String, value: String) {
        val v = values()
        if (v[key] == value) return
        v[key] = value
        saveValues(v)
    }

    @Synchronized override fun remove(key: String) {
        val v = values()
        if (v.remove(key) != null) saveValues(v)
    }

    @Synchronized override fun readQueue(): List<String> {
        if (!queueFile.exists()) return emptyList()
        return queueFile.readLines(Charsets.UTF_8).filter { it.isNotBlank() }
    }

    @Synchronized override fun appendQueue(entry: String) {
        ensureDir()
        FileOutputStream(queueFile, true).use { out ->
            OutputStreamWriter(out, Charsets.UTF_8).use { w ->
                w.write(entry.replace("\n", ""))
                w.write("\n")
            }
        }
    }

    @Synchronized override fun writeQueue(entries: List<String>) {
        if (entries.isEmpty()) {
            if (queueFile.exists()) queueFile.delete()
            return
        }
        ensureDir()
        writeAtomically(queueFile, entries.joinToString(separator = "\n", postfix = "\n") { it.replace("\n", "") })
    }

    @Synchronized override fun isEmpty(): Boolean = !valuesFile.exists() && !queueFile.exists()

    private fun values(): LinkedHashMap<String, String> {
        cache?.let { return it }
        val loaded = LinkedHashMap<String, String>()
        try {
            if (valuesFile.exists()) {
                val parsed = Json.parse(valuesFile.readText(Charsets.UTF_8))
                if (parsed is Map<*, *>) {
                    for ((k, v) in parsed) if (k != null && v != null) loaded[k.toString()] = v.toString()
                }
            }
        } catch (_: Exception) {
            // A corrupt file is replaced on the next write.
        }
        cache = loaded
        return loaded
    }

    private fun saveValues(v: Map<String, String>) {
        ensureDir()
        writeAtomically(valuesFile, Json.encode(v))
    }

    private fun ensureDir() {
        if (!directory.exists() && !directory.mkdirs() && !directory.exists()) {
            throw IOException("Cannot create $directory")
        }
    }

    private fun writeAtomically(target: File, text: String) {
        val tmp = File(target.parentFile, target.name + ".tmp")
        tmp.writeText(text, Charsets.UTF_8)
        if (!tmp.renameTo(target)) {
            target.delete()
            if (!tmp.renameTo(target)) throw IOException("Cannot write $target")
        }
    }
}
