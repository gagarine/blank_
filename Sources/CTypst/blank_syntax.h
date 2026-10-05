#include <stddef.h>
// UTF-8 in, owned UTF-8 JSON out. No pointers survive a call.
char *blank_parse(const char *source);
void blank_string_free(char *string);
