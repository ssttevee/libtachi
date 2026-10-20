package dev.tachi.host

import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketAddress
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.security.cert.Certificate
import java.security.cert.X509Certificate
import java.util.Objects
import javax.net.SocketFactory
import javax.net.ssl.HandshakeCompletedEvent
import javax.net.ssl.HandshakeCompletedListener
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLPeerUnverifiedException
import javax.net.ssl.SSLSession
import javax.net.ssl.SSLSessionContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager
import okhttp3.internal.tls.OkHostnameVerifier
import java.security.KeyStore
import java.security.Principal

/**
 * Sockets whose bytes, and TLS, are handled by the native side (transport.zig).
 * Java's TLS is interpreted on JVMs without a JIT, where a handshake takes
 * seconds. OkHttp still does routing, cookies, redirects and interceptors.
 * Only used when the native side registered these and set
 * `RuntimeConfig.nativeTransport`.
 */
object NativeTransport {
    /** Returns a connection handle; throws on failure. */
    @JvmStatic external fun connect(address: ByteArray, port: Int, timeoutMs: Int): Long
    /** Verifies the peer for `host` against the runtime's CA bundle; returns the TLS version code. */
    @JvmStatic external fun startTls(handle: Long, host: ByteArray): Int
    /** Bytes read, -1 at end of stream, -2 on timeout. */
    @JvmStatic external fun read(handle: Long, buffer: ByteArray, offset: Int, length: Int, timeoutMs: Int): Int
    @JvmStatic external fun write(handle: Long, buffer: ByteArray, offset: Int, length: Int)
    @JvmStatic external fun shutdown(handle: Long)
    @JvmStatic external fun free(handle: Long)
}

/** Frees the native connection only after every thread inside it has returned. */
internal class NativeConnection(private val handle: Long) {
    private var users = 0
    private var closed = false
    val readLock = Any()
    val writeLock = Any()

    fun <T> use(block: (Long) -> T): T {
        synchronized(this) {
            if (closed) throw SocketException("Socket closed")
            users++
        }
        try {
            return block(handle)
        } finally {
            val last = synchronized(this) { --users == 0 && closed }
            if (last) NativeTransport.free(handle)
        }
    }

    fun close() {
        val idle = synchronized(this) {
            if (closed) return
            closed = true
            users == 0
        }
        if (idle) NativeTransport.free(handle) else NativeTransport.shutdown(handle)
    }
}

/** A plain TCP socket; `NativeSslSocketFactory` upgrades it in place. */
internal class NativeSocket : Socket() {
    @Volatile var connection: NativeConnection? = null
        private set
    private var remote: InetSocketAddress? = null
    @Volatile private var closed = false
    @Volatile private var inputShut = false
    @Volatile private var outputShut = false
    @Volatile private var timeoutMs = 0
    private val input by lazy { Input() }
    private val output by lazy { Output() }

    override fun connect(endpoint: SocketAddress?) = connect(endpoint, 0)

    override fun connect(endpoint: SocketAddress?, timeout: Int) {
        val address = endpoint as? InetSocketAddress ?: throw IllegalArgumentException("Unsupported address $endpoint")
        val ip = address.address ?: throw UnknownHostException(address.hostString)
        if (closed) throw SocketException("Socket is closed")
        if (connection != null) throw SocketException("Already connected")
        connection = NativeConnection(NativeTransport.connect(ip.hostAddress.toByteArray(), address.port, timeout))
        remote = address
        if (closed) connection?.close()
    }

    fun live(): NativeConnection {
        if (closed) throw SocketException("Socket closed")
        return connection ?: throw SocketException("Socket is not connected")
    }

    override fun getInputStream(): InputStream = input.also { live() }
    override fun getOutputStream(): OutputStream = output.also { live() }
    override fun setSoTimeout(timeout: Int) { timeoutMs = timeout }
    override fun getSoTimeout(): Int = timeoutMs
    override fun isConnected(): Boolean = connection != null
    override fun isBound(): Boolean = connection != null
    override fun isClosed(): Boolean = closed
    override fun isInputShutdown(): Boolean = inputShut
    override fun isOutputShutdown(): Boolean = outputShut
    override fun shutdownInput() { inputShut = true }
    override fun shutdownOutput() { outputShut = true }
    override fun getInetAddress(): InetAddress? = remote?.address
    override fun getPort(): Int = remote?.port ?: 0
    override fun getRemoteSocketAddress(): SocketAddress? = remote
    override fun getLocalAddress(): InetAddress = InetAddress.getByAddress(ByteArray(4))
    override fun getLocalPort(): Int = -1
    override fun getLocalSocketAddress(): SocketAddress? = null
    // The base Socket would create a second, OS-level socket for these.
    override fun setTcpNoDelay(on: Boolean) {}
    override fun getTcpNoDelay(): Boolean = true
    override fun setKeepAlive(on: Boolean) {}
    override fun getKeepAlive(): Boolean = false
    override fun setSoLinger(on: Boolean, linger: Int) {}
    override fun getSoLinger(): Int = -1
    override fun setReceiveBufferSize(size: Int) {}
    override fun setSendBufferSize(size: Int) {}
    override fun setReuseAddress(on: Boolean) {}
    override fun setOOBInline(on: Boolean) {}
    override fun setTrafficClass(tc: Int) {}
    override fun toString(): String = "NativeSocket[$remote]"

    override fun close() {
        if (closed) return
        closed = true
        connection?.close()
    }

    private inner class Input : InputStream() {
        override fun read(): Int {
            val one = ByteArray(1)
            return if (read(one, 0, 1) <= 0) -1 else one[0].toInt() and 0xff
        }

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            Objects.checkFromIndexSize(off, len, b.size)
            if (len == 0) return 0
            if (inputShut) return -1
            val c = live()
            val n = c.use { h -> synchronized(c.readLock) { NativeTransport.read(h, b, off, len, timeoutMs) } }
            if (n == -2) throw SocketTimeoutException("Read timed out")
            if (n < 0 && closed) throw SocketException("Socket closed")
            return n
        }

        override fun close() = this@NativeSocket.close()
    }

    private inner class Output : OutputStream() {
        override fun write(b: Int) = write(byteArrayOf(b.toByte()), 0, 1)

        override fun write(b: ByteArray, off: Int, len: Int) {
            Objects.checkFromIndexSize(off, len, b.size)
            if (outputShut) throw SocketException("Socket output is shutdown")
            val c = live()
            c.use { h -> synchronized(c.writeLock) { NativeTransport.write(h, b, off, len) } }
        }

        override fun close() = this@NativeSocket.close()
    }
}

/** TLS over a `NativeSocket`. Peer certificates stay native, so the session reports none. */
internal class NativeSslSocket(
    private val base: NativeSocket,
    private val host: String,
    private val autoClose: Boolean,
) : SSLSocket() {
    private var protocols = PROTOCOLS
    private var suites = SUITES
    private val listeners = mutableListOf<HandshakeCompletedListener>()
    @Volatile private var session: NativeSession? = null

    override fun startHandshake() {
        if (session != null) return
        synchronized(this) {
            if (session != null) return
            val version = base.live().use { NativeTransport.startTls(it, host.toByteArray()) }
            val established = NativeSession(host, base.port, if (version == 0x0304) "TLSv1.3" else "TLSv1.2")
            session = established
            val event = HandshakeCompletedEvent(this, established)
            listeners.forEach { it.handshakeCompleted(event) }
        }
    }

    override fun getSession(): SSLSession {
        startHandshake()
        return session!!
    }

    override fun getHandshakeSession(): SSLSession? = null
    override fun getInputStream(): InputStream = base.inputStream.also { startHandshake() }
    override fun getOutputStream(): OutputStream = base.outputStream.also { startHandshake() }
    // OkHttp's Jdk9Platform reads "" as "no ALPN", which selects HTTP/1.1.
    override fun getApplicationProtocol(): String = ""
    override fun getHandshakeApplicationProtocol(): String? = null
    override fun getSupportedCipherSuites(): Array<String> = SUITES.clone()
    override fun getEnabledCipherSuites(): Array<String> = suites.clone()
    override fun setEnabledCipherSuites(suites: Array<String>) { this.suites = suites.clone() }
    override fun getSupportedProtocols(): Array<String> = PROTOCOLS.clone()
    override fun getEnabledProtocols(): Array<String> = protocols.clone()
    override fun setEnabledProtocols(protocols: Array<String>) { this.protocols = protocols.clone() }
    override fun addHandshakeCompletedListener(listener: HandshakeCompletedListener) { listeners += listener }
    override fun removeHandshakeCompletedListener(listener: HandshakeCompletedListener) { listeners -= listener }
    override fun setUseClientMode(mode: Boolean) { if (!mode) throw IllegalArgumentException("Client mode only") }
    override fun getUseClientMode(): Boolean = true
    override fun setNeedClientAuth(need: Boolean) {}
    override fun getNeedClientAuth(): Boolean = false
    override fun setWantClientAuth(want: Boolean) {}
    override fun getWantClientAuth(): Boolean = false
    override fun setEnableSessionCreation(flag: Boolean) {}
    override fun getEnableSessionCreation(): Boolean = true
    override fun setSoTimeout(timeout: Int) { base.soTimeout = timeout }
    override fun getSoTimeout(): Int = base.soTimeout
    override fun isConnected(): Boolean = base.isConnected
    override fun isBound(): Boolean = base.isBound
    override fun isClosed(): Boolean = base.isClosed
    override fun isInputShutdown(): Boolean = base.isInputShutdown
    override fun isOutputShutdown(): Boolean = base.isOutputShutdown
    override fun shutdownInput() = base.shutdownInput()
    override fun shutdownOutput() = base.shutdownOutput()
    override fun getInetAddress(): InetAddress? = base.inetAddress
    override fun getPort(): Int = base.port
    override fun getRemoteSocketAddress(): SocketAddress? = base.remoteSocketAddress
    override fun getLocalAddress(): InetAddress = base.localAddress
    override fun getLocalPort(): Int = base.localPort
    override fun getLocalSocketAddress(): SocketAddress? = null
    override fun setTcpNoDelay(on: Boolean) {}
    override fun getTcpNoDelay(): Boolean = true
    override fun setKeepAlive(on: Boolean) {}
    override fun setSoLinger(on: Boolean, linger: Int) {}
    override fun setReceiveBufferSize(size: Int) {}
    override fun setSendBufferSize(size: Int) {}
    override fun toString(): String = "NativeSslSocket[$host, $base]"

    override fun close() {
        if (autoClose) base.close()
    }

    companion object {
        // Names OkHttp's connection specs recognise; std.crypto.tls picks the real one.
        val SUITES = arrayOf(
            "TLS_AES_128_GCM_SHA256",
            "TLS_AES_256_GCM_SHA384",
            "TLS_CHACHA20_POLY1305_SHA256",
            "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256",
            "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256",
            "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384",
            "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384",
            "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256",
            "TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256",
        )
        val PROTOCOLS = arrayOf("TLSv1.3", "TLSv1.2")
    }
}

internal class NativeSession(private val host: String, private val port: Int, private val protocol: String) : SSLSession {
    private val created = System.currentTimeMillis()
    private val values = HashMap<String, Any>()
    override fun getId(): ByteArray = ByteArray(0)
    override fun getSessionContext(): SSLSessionContext? = null
    override fun getCreationTime(): Long = created
    override fun getLastAccessedTime(): Long = created
    override fun invalidate() {}
    override fun isValid(): Boolean = true
    override fun putValue(name: String, value: Any) { values[name] = value }
    override fun getValue(name: String): Any? = values[name]
    override fun removeValue(name: String) { values.remove(name) }
    override fun getValueNames(): Array<String> = values.keys.toTypedArray()
    override fun getPeerCertificates(): Array<Certificate> = throw SSLPeerUnverifiedException("Verified natively")
    override fun getLocalCertificates(): Array<Certificate>? = null
    @Deprecated("Deprecated in Java")
    override fun getPeerCertificateChain(): Array<javax.security.cert.X509Certificate> = throw SSLPeerUnverifiedException("Verified natively")
    override fun getPeerPrincipal(): Principal = throw SSLPeerUnverifiedException("Verified natively")
    override fun getLocalPrincipal(): Principal? = null
    override fun getCipherSuite(): String = if (protocol == "TLSv1.3") "TLS_AES_128_GCM_SHA256" else "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256"
    override fun getProtocol(): String = protocol
    override fun getPeerHost(): String = host
    override fun getPeerPort(): Int = port
    override fun getPacketBufferSize(): Int = 16709
    override fun getApplicationBufferSize(): Int = 16384
}

internal object NativeSocketFactory : SocketFactory() {
    override fun createSocket(): Socket = NativeSocket()
    override fun createSocket(host: String, port: Int): Socket = NativeSocket().apply { connect(InetSocketAddress(host, port)) }
    override fun createSocket(host: String, port: Int, localHost: InetAddress?, localPort: Int): Socket = createSocket(host, port)
    override fun createSocket(host: InetAddress, port: Int): Socket = NativeSocket().apply { connect(InetSocketAddress(host, port)) }
    override fun createSocket(address: InetAddress, port: Int, localAddress: InetAddress?, localPort: Int): Socket = createSocket(address, port)
}

/** Upgrades `NativeSocket`s natively; any other socket gets Java's TLS. */
internal object NativeSslSocketFactory : SSLSocketFactory() {
    private val java: SSLSocketFactory by lazy { SSLContext.getDefault().socketFactory }

    override fun createSocket(s: Socket, host: String, port: Int, autoClose: Boolean): Socket =
        if (s is NativeSocket) NativeSslSocket(s, host, autoClose) else java.createSocket(s, host, port, autoClose)

    override fun getDefaultCipherSuites(): Array<String> = NativeSslSocket.SUITES.clone()
    override fun getSupportedCipherSuites(): Array<String> = NativeSslSocket.SUITES.clone()
    override fun createSocket(host: String, port: Int): Socket = createSocket(NativeSocketFactory.createSocket(host, port), host, port, true)
    override fun createSocket(host: String, port: Int, localHost: InetAddress?, localPort: Int): Socket = createSocket(host, port)
    override fun createSocket(host: InetAddress, port: Int): Socket = createSocket(NativeSocketFactory.createSocket(host, port), host.hostName, port, true)
    override fun createSocket(address: InetAddress, port: Int, localAddress: InetAddress?, localPort: Int): Socket = createSocket(address, port)
}

/**
 * Handed to OkHttp with the native factory. It reports no issuers, so building
 * clients never loads Java's trust store; Java TLS that asks it to check a
 * chain gets the platform's answer.
 */
internal object NativeTrustManager : X509TrustManager {
    private val platform: X509TrustManager by lazy {
        val factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        factory.init(null as KeyStore?)
        factory.trustManagers.filterIsInstance<X509TrustManager>().first()
    }

    override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) = platform.checkClientTrusted(chain, authType)
    override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) = platform.checkServerTrusted(chain, authType)
    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
}

/** Native sessions were verified for their host during the handshake. */
internal object NativeHostnameVerifier : HostnameVerifier {
    override fun verify(hostname: String, session: SSLSession): Boolean =
        session is NativeSession || OkHostnameVerifier.verify(hostname, session)
}
