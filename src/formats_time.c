#include <stdint.h>
#include <time.h>

int64_t tachi_local_date(int year, int month, int day) {
    struct tm date = {0};
    date.tm_year = year - 1900;
    date.tm_mon = month - 1;
    date.tm_mday = day;
    date.tm_isdst = -1;
    return (int64_t)mktime(&date) * 1000;
}

int tachi_date_parts(int64_t milliseconds, int *parts) {
    time_t seconds = (time_t)(milliseconds / 1000);
    struct tm date;
    if (!localtime_r(&seconds, &date)) return 0;
    parts[0] = date.tm_year + 1900;
    parts[1] = date.tm_mon + 1;
    parts[2] = date.tm_mday;
    return 1;
}
