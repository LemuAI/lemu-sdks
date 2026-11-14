package com.lemuai.analytics.core

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.ThreadFactory
import java.util.concurrent.TimeUnit

/** Wall clock in epoch milliseconds. Injected so tests can move time. */
fun interface Clock {
    fun now(): Long

    companion object {
        @JvmField val SYSTEM: Clock = Clock { System.currentTimeMillis() }
    }
}

/** Handle for a scheduled task. */
fun interface Cancellable {
    fun cancel()
}

/**
 * Runs the SDK's work. All state changes happen on tasks given to this scheduler, one at a time,
 * so the client needs no locks. Tests inject a synchronous scheduler with a fake clock.
 */
interface TaskScheduler {
    fun execute(task: Runnable)

    fun schedule(delayMillis: Long, task: Runnable): Cancellable
}

/** One daemon background thread. */
class BackgroundScheduler : TaskScheduler {
    private val executor: ScheduledExecutorService =
        Executors.newSingleThreadScheduledExecutor(
            ThreadFactory { r ->
                Thread(r, "lemu-analytics").apply {
                    isDaemon = true
                    priority = Thread.MIN_PRIORITY + 1
                }
            },
        )

    override fun execute(task: Runnable) {
        try {
            executor.execute(task)
        } catch (_: Exception) {
            // Rejected after shutdown: nothing to do.
        }
    }

    override fun schedule(delayMillis: Long, task: Runnable): Cancellable {
        return try {
            val f: ScheduledFuture<*> = executor.schedule(task, delayMillis, TimeUnit.MILLISECONDS)
            Cancellable { f.cancel(false) }
        } catch (_: Exception) {
            Cancellable { }
        }
    }
}

/** Debug logging. The Android module logs to Logcat with the tag `Lemu`. */
interface LemuLogger {
    fun debug(message: String)

    fun warn(message: String, error: Throwable? = null)

    companion object {
        @JvmField val STDOUT: LemuLogger =
            object : LemuLogger {
                override fun debug(message: String) = println("[Lemu] $message")

                override fun warn(message: String, error: Throwable?) =
                    println("[Lemu] WARN $message" + (error?.let { " ($it)" } ?: ""))
            }
    }
}

/** The outcome of one POST. */
sealed class HttpResult {
    /** The server answered with [code]. */
    data class Response(val code: Int) : HttpResult()

    /**
     * The request failed without a status. [mayHaveReachedServer] is false when the connection
     * was never made (offline, DNS failure, refused), so the batch cannot have been processed.
     */
    data class Failure(val error: Throwable, val mayHaveReachedServer: Boolean) : HttpResult()
}

/** Sends request bodies. The default uses [HttpURLConnection] so host apps get no OkHttp clash. */
interface HttpTransport {
    fun post(url: String, body: ByteArray, headers: Map<String, String>): HttpResult
}

class UrlConnectionTransport(
    private val connectTimeoutMillis: Int = 15_000,
    private val readTimeoutMillis: Int = 20_000,
) : HttpTransport {
    override fun post(url: String, body: ByteArray, headers: Map<String, String>): HttpResult {
        var conn: HttpURLConnection? = null
        var sent = false
        return try {
            conn = URL(url).openConnection() as HttpURLConnection
            conn.requestMethod = "POST"
            conn.connectTimeout = connectTimeoutMillis
            conn.readTimeout = readTimeoutMillis
            conn.doOutput = true
            conn.useCaches = false
            conn.instanceFollowRedirects = false
            conn.setFixedLengthStreamingMode(body.size)
            for ((k, v) in headers) conn.setRequestProperty(k, v)
            conn.outputStream.use { it.write(body) }
            sent = true
            val code = conn.responseCode
            // Drain the body so the connection can be reused.
            try {
                (if (code >= 400) conn.errorStream else conn.inputStream)?.use { s ->
                    val buf = ByteArray(1024)
                    while (s.read(buf) != -1) { /* discard */ }
                }
            } catch (_: IOException) {
            }
            HttpResult.Response(code)
        } catch (e: Exception) {
            // A body that was never fully written cannot have been processed by the server.
            HttpResult.Failure(e, mayHaveReachedServer = sent)
        } finally {
            try {
                conn?.disconnect()
            } catch (_: Exception) {
            }
        }
    }
}
