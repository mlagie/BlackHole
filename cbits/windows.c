/* Preserve the directory kind of Windows symbolic links, even when dangling. */
#ifdef _WIN32
#include <windows.h>
#include <wchar.h>
int bh_windows_directory_attribute(const wchar_t *path) {
    DWORD attributes = GetFileAttributesW(path);
    if (attributes == INVALID_FILE_ATTRIBUTES) return -1;
    return (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
}
#else
#include <wchar.h>
int bh_windows_directory_attribute(const wchar_t *path) { (void)path; return 0; }
#endif
