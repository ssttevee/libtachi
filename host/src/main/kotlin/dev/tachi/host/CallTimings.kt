package dev.tachi.host

import okhttp3.Call
import okhttp3.EventListener
import okhttp3.Handshake
import okhttp3.Protocol
import okhttp3.Response
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Proxy

/** Logs one line per HTTP call: where its time went, in milliseconds. */
object CallTimings : EventListener.Factory {
    override fun create(call: Call): EventListener = Timer()

    private class Timer : EventListener() {
        private val start = System.nanoTime()
        private var mark = 0L
        private var dns = 0L
        private var connect = 0L
        private var tls = 0L
        private var headers = -1L

        private fun now() = System.nanoTime()
        private fun since(from: Long) = (now() - from) / 1_000_000

        override fun dnsStart(call: Call, domainName: String) { mark = now() }
        override fun dnsEnd(call: Call, domainName: String, inetAddressList: List<InetAddress>) { dns += since(mark) }
        override fun connectStart(call: Call, inetSocketAddress: InetSocketAddress, proxy: Proxy) { mark = now() }
        override fun secureConnectStart(call: Call) { connect += since(mark); mark = now() }
        override fun secureConnectEnd(call: Call, handshake: Handshake?) { tls += since(mark); mark = now() }
        override fun connectEnd(call: Call, inetSocketAddress: InetSocketAddress, proxy: Proxy, protocol: Protocol?) {
            if (tls == 0L) connect += since(mark)
        }
        override fun responseHeadersEnd(call: Call, response: Response) { headers = since(start) }
        override fun callEnd(call: Call) = log(call, "")
        override fun callFailed(call: Call, ioe: IOException) = log(call, " failed=${ioe.javaClass.simpleName}")

        private fun log(call: Call, suffix: String) {
            val url = call.request().url
            TachiLog.i(
                "http",
                "${call.request().method} ${url.host}${url.encodedPath} dns_ms=$dns connect_ms=$connect tls_ms=$tls " +
                    "headers_ms=$headers total_ms=${since(start)}$suffix",
            )
        }
    }
}
