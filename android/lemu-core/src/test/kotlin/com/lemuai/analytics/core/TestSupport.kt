package com.lemuai.analytics.core

import com.fasterxml.jackson.databind.ObjectMapper
import com.networknt.schema.JsonSchema
import com.networknt.schema.JsonSchemaFactory
import com.networknt.schema.SpecVersion
import com.sun.net.httpserver.HttpServer
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import java.io.File
import java.net.InetSocketAddress
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CopyOnWriteArrayList

/** Root of the lemu-sdks checkout (holds spec/ and conformance/). */
val sdksRoot: File by lazy {
    val prop = System.getProperty("lemu.sdks.root")
    if (prop != null) File(prop) else File("../..").canonicalFile
}

class FakeClock(var nowMillis: Long = 1_794_650_400_000L) : Clock {
    override fun now(): Long = nowMillis
}

/**
 * Runs tasks synchronously on the calling thread, in order (a task that schedules another runs
 * it after itself). Delayed tasks run when [advance] moves the fake clock past them.
 */
class ManualScheduler(private val clock: FakeClock) : TaskScheduler {
    private class Timed(val dueAt: Long, val seq: Long, val task: Runnable) {
        @Volatile var cancelled = false
    }

    private val ready = ArrayDeque<Runnable>()
    private val timed = ArrayList<Timed>()
    private var running = false
    private var seq = 0L

    @Synchronized override fun execute(task: Runnable) {
        ready.addLast(task)
        drain()
    }

    @Synchronized override fun schedule(
        delayMillis: Long,
        task: Runnable,
    ): Cancellable {
        val t = Timed(clock.now() + delayMillis, seq++, task)
        timed.add(t)
        return Cancellable { t.cancelled = true }
    }

    @Synchronized fun advance(millis: Long) {
        val target = clock.now() + millis
        while (true) {
            timed.removeAll { it.cancelled }
            val next = timed.filter { it.dueAt <= target }.minWithOrNull(compareBy<Timed>({ it.dueAt }, { it.seq })) ?: break
            timed.remove(next)
            if (next.dueAt > clock.nowMillis) clock.nowMillis = next.dueAt
            execute(next.task)
        }
        clock.nowMillis = target
    }

    private fun drain() {
        if (running) return
        running = true
        try {
            while (ready.isNotEmpty()) ready.removeFirst().run()
        } finally {
            running = false
        }
    }
}

/** A local ingest server on 127.0.0.1 that records bodies and answers with statuses chosen by the test. */
class FakeIngestServer : AutoCloseable {
    class Recorded(val body: String, val headers: Map<String, List<String>>, val status: Int, val path: String) {
        @Suppress("UNCHECKED_CAST")
        val json: Map<String, Any?> by lazy { Json.parse(body) as Map<String, Any?> }

        @Suppress("UNCHECKED_CAST")
        val batch: List<Map<String, Any?>> get() = json["batch"] as List<Map<String, Any?>>

        fun header(name: String): String? = headers.entries.firstOrNull { it.key.equals(name, ignoreCase = true) }?.value?.firstOrNull()
    }

    val requests = CopyOnWriteArrayList<Recorded>()
    private val statuses = ConcurrentLinkedQueue<Int>()

    @Volatile var defaultStatus = 204

    private val server: HttpServer = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)

    init {
        server.createContext("/") { ex ->
            val body = ex.requestBody.readBytes().toString(Charsets.UTF_8)
            val status = statuses.poll() ?: defaultStatus
            requests.add(Recorded(body, HashMap(ex.requestHeaders), status, ex.requestURI.path))
            ex.sendResponseHeaders(status, -1)
            ex.close()
        }
        server.start()
    }

    val url: String = "http://127.0.0.1:${server.address.port}"
    private var closed = false

    fun respondWith(vararg codes: Int) {
        codes.forEach { statuses.add(it) }
    }

    /** All messages from requests the server accepted. */
    fun delivered(): List<Map<String, Any?>> = requests.filter { it.status in 200..299 }.flatMap { it.batch }

    @Synchronized override fun close() {
        if (closed) return
        closed = true
        server.stop(0)
    }
}

object BatchSchema {
    private val schema: JsonSchema by lazy {
        val factory = JsonSchemaFactory.getInstance(SpecVersion.VersionFlag.V202012)
        File(sdksRoot, "conformance/batch.schema.json").inputStream().use { factory.getSchema(it) }
    }
    private val mapper = ObjectMapper()

    fun assertValid(body: String) {
        val errors = schema.validate(mapper.readTree(body))
        if (errors.isNotEmpty()) fail("Request body does not match batch.schema.json: $errors\n$body")
    }
}

/** Collects debug output so tests stay quiet and can assert on warnings. */
class RecordingLogger : LemuLogger {
    val lines = CopyOnWriteArrayList<String>()

    override fun debug(message: String) {
        lines.add(message)
    }

    override fun warn(
        message: String,
        error: Throwable?,
    ) {
        lines.add("WARN $message")
    }
}

const val TEST_UA = "lemu-android/1.0.0 (Android 14; Pixel 8)"

val testContext: Map<String, Any?> =
    linkedMapOf(
        "app" to linkedMapOf("name" to "Brand", "version" to "3.2.0", "build" to "320", "namespace" to "com.brand.app"),
        "device" to linkedMapOf("manufacturer" to "Google", "model" to "Pixel 8", "type" to "phone"),
        "os" to linkedMapOf("name" to "Android", "version" to "14"),
        "screen" to linkedMapOf("width" to 1080, "height" to 2400, "density" to 2.625),
        "locale" to "en-IN",
        "timezone" to "Asia/Kolkata",
        "userAgent" to TEST_UA,
    )

/** Builds a client wired to the fake server, fake clock and synchronous scheduler. */
class Harness(
    val server: FakeIngestServer = FakeIngestServer(),
    val storage: Storage = InMemoryStorage(),
    val clock: FakeClock = FakeClock(),
) : AutoCloseable {
    val scheduler = ManualScheduler(clock)
    val logger = RecordingLogger()

    fun client(
        requireConsent: Boolean = false,
        flushAt: Int = 20,
        maxQueueSize: Int = 1_000,
        apiHost: String = server.url,
        installReferrer: InstallReferrerSource? = null,
        transport: HttpTransport = UrlConnectionTransport(2_000, 5_000),
    ): LemuClient =
        LemuClient(
            config =
                LemuConfig(
                    writeKey = "pk_test_123",
                    apiHost = apiHost,
                    userAgent = TEST_UA,
                    requireConsent = requireConsent,
                    debug = true,
                    flushAt = flushAt,
                    maxQueueSize = maxQueueSize,
                ),
            storage = storage,
            contextProvider = { testContext },
            transport = transport,
            clock = clock,
            scheduler = scheduler,
            logger = logger,
            installReferrerSource = installReferrer,
        )

    /** Every recorded body must match the shared schema. */
    fun assertAllValid() {
        for (r in server.requests) {
            assertTrue("path ${r.path}", r.path == "/api/v1/pixel/batch")
            BatchSchema.assertValid(r.body)
        }
    }

    override fun close() {
        server.close()
    }
}

val UUID_V4 = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
