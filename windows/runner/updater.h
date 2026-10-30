#ifndef HOPBOARD_UPDATER_H_
#define HOPBOARD_UPDATER_H_
#include <windows.h>
#include <optional>
#include <string>
std::wstring UpdateDirectory();
bool LaunchUpdate(const std::wstring& path, const std::wstring& hash);
std::optional<int> RunUpdateHelper();
#endif
