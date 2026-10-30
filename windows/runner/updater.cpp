#include "updater.h"
#include <shellapi.h>
#include <shlobj.h>
#include <wincrypt.h>
#include <vector>
#include <cwctype>

std::wstring UpdateDirectory() {
  PWSTR local = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE, nullptr, &local))) return {};
  const std::wstring root = std::wstring(local) + L"\\LocalClipboard";
  CoTaskMemFree(local);
  if (!CreateDirectoryW(root.c_str(), nullptr) && GetLastError() != ERROR_ALREADY_EXISTS) return {};
  const auto directory = root + L"\\Updates";
  if (!CreateDirectoryW(directory.c_str(), nullptr) && GetLastError() != ERROR_ALREADY_EXISTS) return {};
  return directory;
}

namespace {
bool Verified(const std::wstring& path, const std::wstring& expected) {
  const auto root = UpdateDirectory() + L"\\";
  wchar_t full[32768];
  const DWORD length = GetFullPathNameW(path.c_str(), 32768, full, nullptr);
  if (root.size() < 10 || !length || length >= 32768 || path.find(L'"') != std::wstring::npos ||
      _wcsnicmp(full, root.c_str(), root.size()) != 0 || expected.size() != 64) return false;
  for (const wchar_t c : expected) if (!iswxdigit(c)) return false;
  HANDLE file = CreateFileW(full, GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
    FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  BY_HANDLE_FILE_INFORMATION info{};
  LARGE_INTEGER size{};
  bool valid = GetFileInformationByHandle(file, &info) && !(info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) &&
    GetFileSizeEx(file, &size) && size.QuadPart > 0 && size.QuadPart <= 256LL * 1024 * 1024;
  // Resolve intermediate junctions too: an update must remain in our own cache.
  wchar_t final_path[32768];
  const DWORD final_length = GetFinalPathNameByHandleW(file, final_path, 32768, FILE_NAME_NORMALIZED);
  const std::wstring canonical_root = L"\\\\?\\" + root;
  valid = valid && final_length && final_length < 32768 &&
    _wcsnicmp(final_path, canonical_root.c_str(), canonical_root.size()) == 0;
  HCRYPTPROV provider = 0;
  HCRYPTHASH hash = 0;
  valid = valid && CryptAcquireContextW(&provider, nullptr, nullptr, PROV_RSA_AES, CRYPT_VERIFYCONTEXT) &&
    CryptCreateHash(provider, CALG_SHA_256, 0, 0, &hash);
  std::vector<BYTE> buffer(65536);
  while (valid) {
    DWORD read = 0;
    if (!ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()), &read, nullptr)) { valid = false; break; }
    if (!read) break;
    valid = CryptHashData(hash, buffer.data(), read, 0) != FALSE;
  }
  BYTE digest[32]; DWORD digest_size = sizeof(digest);
  valid = valid && CryptGetHashParam(hash, HP_HASHVAL, digest, &digest_size, 0);
  if (valid) {
    const wchar_t hex[] = L"0123456789abcdef";
    std::wstring actual;
    for (const BYTE byte : digest) { actual += hex[byte >> 4]; actual += hex[byte & 15]; }
    valid = _wcsicmp(actual.c_str(), expected.c_str()) == 0;
  }
  if (hash) CryptDestroyHash(hash);
  if (provider) CryptReleaseContext(provider, 0);
  CloseHandle(file);
  return valid;
}
}

bool LaunchUpdate(const std::wstring& path, const std::wstring& hash) {
  if (!Verified(path, hash)) return false;
  wchar_t exe[32768];
  const DWORD size = GetModuleFileNameW(nullptr, exe, 32768);
  if (!size || size >= 32768) return false;
  std::wstring command = L"\"" + std::wstring(exe) + L"\" --hopboard-install-update " +
    std::to_wstring(GetCurrentProcessId()) + L" \"" + path + L"\" " + hash;
  STARTUPINFOW startup{}; startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  if (!CreateProcessW(exe, command.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW,
      nullptr, nullptr, &startup, &process)) return false;
  CloseHandle(process.hThread); CloseHandle(process.hProcess);
  return true;
}

std::optional<int> RunUpdateHelper() {
  int count = 0;
  LPWSTR* args = CommandLineToArgvW(GetCommandLineW(), &count);
  if (!args) return std::nullopt;
  if (count < 2 || std::wstring(args[1]) != L"--hopboard-install-update") {
    LocalFree(args); return std::nullopt;
  }
  bool success = false;
  if (count == 5) {
    wchar_t* end = nullptr;
    const DWORD pid = wcstoul(args[2], &end, 10);
    if (pid && end && !*end) {
      HANDLE parent = OpenProcess(SYNCHRONIZE, FALSE, pid);
      const bool exited = parent ? WaitForSingleObject(parent, 30000) == WAIT_OBJECT_0 :
        GetLastError() == ERROR_INVALID_PARAMETER;
      if (parent) CloseHandle(parent);
      if (exited && Verified(args[3], args[4])) {
        success = reinterpret_cast<INT_PTR>(ShellExecuteW(nullptr, L"open", args[3], nullptr, nullptr, SW_SHOWNORMAL)) > 32;
      }
    }
  }
  LocalFree(args);
  if (!success) MessageBoxW(nullptr, L"The update could not start. Open Hopboard and try Update again.",
    L"Hopboard update", MB_OK | MB_ICONERROR);
  return success ? EXIT_SUCCESS : EXIT_FAILURE;
}
