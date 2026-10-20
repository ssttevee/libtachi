package dev.tachi.host

import java.net.URI
import java.net.URISyntaxException

/** Fast paths that must match the code they shortcut. */
object HostCompatTest {
    private fun viaUri(orig: String): String = try {
        val uri = URI(orig.replace(" ", "%20"))
        var out = uri.path
        if (uri.query != null) out += "?" + uri.query
        if (uri.fragment != null) out += "#" + uri.fragment
        out
    } catch (_: URISyntaxException) {
        orig
    }

    private fun viaRegex(input: String): String = Regex("[\\x00-\\x1f]*").replace(input, "")

    @JvmStatic fun main(args: Array<String>) {
        val urls = listOf(
            "https://fanfox.net/manga/tales_of_demons_and_gods/c534.5/1.html",
            "https://fanfox.net/manga/x/?page=2#top", "https://fanfox.net", "https://fanfox.net?x=1",
            "https://user@host:8080/a/b;c?d=e&f=g#h", "http://host#frag", "https:///path", "HTTPS://Host/P",
            "//cdn.example/a/b", "/relative/path?q", "relative",
            "https://host/a%20b", "https://host/a b", "https://host/a#b#c", "https://[::1]/x",
            "https://host/ä", "https://host/path?", "https://host/path#", "a+b://h/p", "1http://h/p",
            "https://host/a/../b/./c", "https://host:abc/x", "",
        )
        for (u in urls) check(urlWithoutDomain(u) == viaUri(u)) { "$u: ${urlWithoutDomain(u)} != ${viaUri(u)}" }
        val method = Class.forName("org.jsoup.internal.StringUtil").getDeclaredMethod("stripControlChars", String::class.java)
        method.isAccessible = true
        for (s in listOf("", "plain", "\u0000a\tb\nc\u001f", "\t\t", "x\u0020y\u007f", "日本\r\n語")) {
            check(method.invoke(null, s) == viaRegex(s)) { "stripControlChars(${s.toByteArray().toList()})" }
        }
        println("PASS: urlWithoutDomain matches java.net.URI; jsoup stripControlChars matches its regex")
    }
}
