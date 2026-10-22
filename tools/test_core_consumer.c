/* Link only libtachicore; including both headers also checks coexistence. */
#include "tachicore.h"
#include "tachi.h"
#include <assert.h>
#include <string.h>

_Static_assert(sizeof(tachicore_config) == sizeof(tachi_config), "configuration ABI mismatch");
_Static_assert(offsetof(tachicore_config, native_transport) == offsetof(tachi_config, native_transport), "configuration field mismatch");

int main(void) {
    const uint8_t index[] = {0x0a, 4, 'T', 'e', 's', 't'};
    char *json = NULL;
    assert(tachicore_parse_index(index, sizeof(index), &json) == TACHICORE_OK);
    assert(json && strstr(json, "Test"));
    tachicore_free(json);
    assert(tachicore_parse_index(NULL, 1, NULL) == TACHICORE_E_INVALID_ARGUMENT);
    assert(tachicore_parse_index(NULL, 0, NULL) == TACHICORE_E_INVALID_INDEX);
    assert(strcmp(tachicore_last_error(), "InvalidIndex") == 0);
    assert(tachicore_load(NULL, "owned.jar", NULL) == TACHICORE_E_INVALID_ARGUMENT);
    assert(strncmp(tachicore_default_index_url(), "https://", 8) == 0);
    return 0;
}
