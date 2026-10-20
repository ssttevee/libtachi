package dev.tachi.host

import java.net.URI
import java.net.URISyntaxException

/**
 * Path, query and fragment of `orig`, as Mihon's HttpSource.getUrlWithoutDomain
 * returns them via java.net.URI (which decodes escapes). Plain absolute URLs
 * skip URI: without `%` or characters it would reject, decoding changes
 * nothing, and URI's parser is slow when interpreted.
 */
fun urlWithoutDomain(orig: String): String = plainWithoutDomain(orig) ?: try {
    val uri = URI(orig.replace(" ", "%20"))
    var out = uri.path
    if (uri.query != null) out += "?" + uri.query
    if (uri.fragment != null) out += "#" + uri.fragment
    out
} catch (_: URISyntaxException) {
    orig
}

private fun plainWithoutDomain(url: String): String? {
    var fragments = 0
    for (c in url) {
        val plain = c in 'a'..'z' || c in 'A'..'Z' || c in '0'..'9' || c in "-._~!$&'()*+,;=:@/?#"
        if (!plain) return null
        if (c == '#') fragments++
    }
    if (fragments > 1) return null
    val scheme = url.indexOf("://")
    if (scheme <= 0 || !url[0].isLetter() || url.substring(0, scheme).any { !(it.isLetterOrDigit() || it in "+-.") }) return null
    var start = scheme + 3
    while (start < url.length && url[start] !in "/?#") start++
    return url.substring(start)
}
