#include <winsock2.h>
#include <ws2ipdef.h>
#include "clipboard_bridge.h"
#include <iphlpapi.h>
#include <netioapi.h>
#include <wincrypt.h>
#include <shlobj.h>
#include <vector>
#include <algorithm>
#include <string>
#include <cstring>
#include "resource.h"

namespace {
constexpr UINT kTrayMessage = WM_APP + 41;
constexpr UINT kNetworkMessage = WM_APP + 42;
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;

std::string Utf8(const std::wstring& value) {
  if (value.empty()) return {};
  const int size = WideCharToMultiByte(CP_UTF8, 0, value.data(),
    static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  std::string result(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
    result.data(), size, nullptr, nullptr);
  return result;
}

std::wstring Wide(const std::string& value) {
  if (value.empty()) return {};
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
    static_cast<int>(value.size()), nullptr, 0);
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
    static_cast<int>(value.size()), result.data(), size);
  return result;
}

// A string argument, or nullptr when missing or of another type.
const std::string* StringArg(const Map* args, const char* key) {
  if (!args) return nullptr;
  const auto entry = args->find(Value(key));
  return entry == args->end() ? nullptr : std::get_if<std::string>(&entry->second);
}

int64_t Integer(const Value& value) {
  if (const auto* number = std::get_if<int32_t>(&value)) return *number;
  if (const auto* number = std::get_if<int64_t>(&value)) return *number;
  return -1;
}

// Password managers and other private sources mark clipboard data with these
// formats so monitors skip it. Call only while the clipboard is open.
bool IsPrivateClipboard() {
  for (const wchar_t* name : {L"ExcludeClipboardContentFromMonitorProcessing",
                              L"Clipboard Viewer Ignore"}) {
    const UINT format = RegisterClipboardFormatW(name);
    if (format && IsClipboardFormatAvailable(format)) return true;
  }
  for (const wchar_t* name : {L"CanIncludeInClipboardHistory",
                              L"CanUploadToCloudClipboard"}) {
    const UINT format = RegisterClipboardFormatW(name);
    const HANDLE memory = format ? GetClipboardData(format) : nullptr;
    if (!memory || GlobalSize(memory) < sizeof(DWORD)) continue;
    const auto* value = static_cast<const DWORD*>(GlobalLock(memory));
    if (!value) continue;
    const bool denied = *value == 0;
    GlobalUnlock(memory);
    if (denied) return true;
  }
  return false;
}

// Shared text lives for minutes in the app; keep it out of Win+V history and
// Cloud Clipboard. Call only after EmptyClipboard while the clipboard is open.
void ExcludeFromHistory() {
  for (const wchar_t* name : {L"CanIncludeInClipboardHistory",
                              L"CanUploadToCloudClipboard"}) {
    const UINT format = RegisterClipboardFormatW(name);
    HGLOBAL flag = format ? GlobalAlloc(GMEM_MOVEABLE, sizeof(DWORD)) : nullptr;
    if (!flag) continue;
    auto* value = static_cast<DWORD*>(GlobalLock(flag));
    if (!value) { GlobalFree(flag); continue; }
    *value = 0;
    GlobalUnlock(flag);
    if (!SetClipboardData(format, flag)) GlobalFree(flag);
  }
}

void CALLBACK NetworkChanged(PVOID context, PMIB_IPINTERFACE_ROW,
                             MIB_NOTIFICATION_TYPE) {
  PostMessageW(reinterpret_cast<HWND>(context), kNetworkMessage, 0, 0);
}
}

ClipboardBridge::ClipboardBridge(HWND window, flutter::BinaryMessenger* messenger)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<Value>>(
    messenger, "dev.localclipboard/native", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const flutter::MethodCall<Value>& call,
      std::unique_ptr<flutter::MethodResult<Value>> result) {
    const auto& method = call.method_name();
    if (method == "secureRead" || method == "secureWrite" || method == "secureDelete") {
      const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      const auto* key_value = StringArg(args, "key");
      if (!key_value) {
        result->Error("storage", "Storage key missing."); return;
      }
      const std::string key = *key_value;
      if (key != "identity.v1" && key != "trust.v1") {
        result->Error("storage", "Unsupported storage key."); return;
      }
      PWSTR local = nullptr;
      if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE, nullptr, &local))) {
        result->Error("storage", "Private storage directory unavailable."); return;
      }
      const std::wstring directory = std::wstring(local) + L"\\LocalClipboard";
      CoTaskMemFree(local);
      if (!CreateDirectoryW(directory.c_str(), nullptr) && GetLastError() != ERROR_ALREADY_EXISTS) {
        result->Error("storage", "Private storage directory unavailable."); return;
      }
      const std::wstring path = directory + L"\\" + Wide(key) + L".dpapi";
      if (method == "secureDelete") {
        if (!DeleteFileW(path.c_str()) && GetLastError() != ERROR_FILE_NOT_FOUND) {
          result->Error("storage", "Could not remove private storage."); return;
        }
        DeleteFileW((path + L".tmp").c_str());
        result->Success();
      } else if (method == "secureRead") {
        HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
          OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file == INVALID_HANDLE_VALUE) {
          if (GetLastError() == ERROR_FILE_NOT_FOUND) result->Success();
          else result->Error("storage", "Could not read private storage.");
          return;
        }
        const DWORD size = GetFileSize(file, nullptr);
        std::vector<BYTE> bytes(size <= 524288 ? size : 0);
        DWORD read = 0;
        const bool ok = !bytes.empty() && ReadFile(file, bytes.data(), size, &read, nullptr) && read == size;
        CloseHandle(file);
        DATA_BLOB input{static_cast<DWORD>(bytes.size()), bytes.data()}, output{};
        if (!ok || !CryptUnprotectData(&input, nullptr, nullptr, nullptr, nullptr,
            CRYPTPROTECT_UI_FORBIDDEN, &output)) {
          result->Error("storage", "Could not decrypt private storage."); return;
        }
        std::string value(reinterpret_cast<char*>(output.pbData), output.cbData);
        SecureZeroMemory(output.pbData, output.cbData); LocalFree(output.pbData);
        result->Success(Value(value));
      } else {
        const auto* value_arg = StringArg(args, "value");
        if (!value_arg) { result->Error("storage", "Storage value missing."); return; }
        const std::string& value = *value_arg;
        if (value.size() > 262144) { result->Error("storage", "Storage value too large."); return; }
        DATA_BLOB input{static_cast<DWORD>(value.size()),
          reinterpret_cast<BYTE*>(const_cast<char*>(value.data()))}, output{};
        if (!CryptProtectData(&input, L"LocalClipboard", nullptr, nullptr, nullptr,
            CRYPTPROTECT_UI_FORBIDDEN, &output)) {
          result->Error("storage", "Could not encrypt private storage."); return;
        }
        const auto temporary = path + L".tmp";
        HANDLE file = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr,
          CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        DWORD written = 0;
        const bool ok = file != INVALID_HANDLE_VALUE &&
          WriteFile(file, output.pbData, output.cbData, &written, nullptr) &&
          written == output.cbData && FlushFileBuffers(file);
        if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
        LocalFree(output.pbData);
        if (!ok || !MoveFileExW(temporary.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
          DeleteFileW(temporary.c_str()); result->Error("storage", "Could not save private storage."); return;
        }
        result->Success();
      }
    } else if (method == "initialize") {
      if (!AddClipboardFormatListener(window_)) {
        result->Error("clipboard", "Could not observe clipboard changes."); return;
      }
      tray_.cbSize = sizeof(tray_);
      tray_.hWnd = window_;
      tray_.uID = 1;
      tray_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
      tray_.uCallbackMessage = kTrayMessage;
      tray_.hIcon = LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON));
      wcscpy_s(tray_.szTip, L"LocalClipboard");
      tray_ready_ = Shell_NotifyIconW(NIM_ADD, &tray_) != FALSE;
      NotifyIpInterfaceChange(AF_INET, NetworkChanged, window_, FALSE,
        &network_notification_);
      result->Success();
    } else if (method == "readClipboard") {
      if (!OpenClipboard(window_)) {
        result->Error("busy", "Clipboard is temporarily busy."); return;
      }
      Map data;
      const DWORD revision = GetClipboardSequenceNumber();
      data[Value("revision")] = Value(static_cast<int64_t>(revision));
      data[Value("ownWrite")] = Value(revision != 0 && revision == own_revision_);
      data[Value("sensitive")] = Value(IsPrivateClipboard());
      const HANDLE memory = GetClipboardData(CF_UNICODETEXT);
      if (memory) {
        const auto* text = static_cast<const wchar_t*>(GlobalLock(memory));
        if (text) {
          const size_t capacity = GlobalSize(memory) / sizeof(wchar_t);
          const size_t bound = (std::min)(capacity, static_cast<size_t>(65537));
          const size_t length = wcsnlen_s(text, bound);
          if (length < bound) {
            auto utf8 = Utf8(std::wstring(text, length));
            if (utf8.size() <= 65536) data[Value("text")] = Value(utf8);
          }
          GlobalUnlock(memory);
        }
      }
      CloseClipboard();
      result->Success(Value(data));
    } else if (method == "writeClipboard") {
      const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      if (!args || !args->count(Value("text"))) {
        result->Error("arguments", "Text is required."); return;
      }
      const auto* text = std::get_if<std::string>(&args->at(Value("text")));
      if (!text || text->size() > 65536 || text->find('\0') != std::string::npos) {
        result->Error("text", "Unsupported clipboard text."); return;
      }
      const auto wide = Wide(*text);
      HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, (wide.size() + 1) * sizeof(wchar_t));
      if (!memory) { result->Error("memory", "Clipboard allocation failed."); return; }
      auto* buffer = GlobalLock(memory);
      if (!buffer) { GlobalFree(memory); result->Error("memory", "Clipboard allocation failed."); return; }
      memcpy(buffer, wide.c_str(), (wide.size() + 1) * sizeof(wchar_t));
      GlobalUnlock(memory);
      if (!OpenClipboard(window_)) {
        GlobalFree(memory); result->Error("busy", "Clipboard is temporarily busy."); return;
      }
      const auto expected = args->find(Value("expectedRevision"));
      if (expected != args->end() && Integer(expected->second) >= 0 &&
          Integer(expected->second) != static_cast<int64_t>(GetClipboardSequenceNumber())) {
        CloseClipboard(); GlobalFree(memory); result->Success(Value(false)); return;
      }
      const bool success = EmptyClipboard() && SetClipboardData(CF_UNICODETEXT, memory);
      if (success) {
        ExcludeFromHistory();
        own_revision_ = GetClipboardSequenceNumber();
      } else {
        GlobalFree(memory);
      }
      CloseClipboard();
      if (success) result->Success(Value(true));
      else result->Error("clipboard", "Clipboard write failed.");
    } else if (method == "updateTray") {
      const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      const auto paused = args && args->count(Value("paused"))
        ? std::get_if<bool>(&args->at(Value("paused"))) : nullptr;
      const auto* status = StringArg(args, "status");
      if (!paused || !status) { result->Error("arguments", "Tray state is required."); return; }
      paused_ = *paused;
      const auto tip = Wide("LocalClipboard - " + *status);
      wcsncpy_s(tray_.szTip, tip.c_str(), _TRUNCATE);
      if (tray_ready_) Shell_NotifyIconW(NIM_MODIFY, &tray_);
      result->Success();
    } else if (method == "notify") {
      // Quiet tray notice for background clipboard replacement; never content.
      const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      const auto* title = StringArg(args, "title");
      const auto* body = StringArg(args, "body");
      if (!title || !body) { result->Error("arguments", "Notice text is required."); return; }
      if (tray_ready_ && GetForegroundWindow() != window_) {
        NOTIFYICONDATAW notice = tray_;
        notice.uFlags = NIF_INFO;
        notice.dwInfoFlags = NIIF_INFO | NIIF_NOSOUND;
        wcsncpy_s(notice.szInfoTitle, Wide(*title).c_str(), _TRUNCATE);
        wcsncpy_s(notice.szInfo, Wide(*body).c_str(), _TRUNCATE);
        Shell_NotifyIconW(NIM_MODIFY, &notice);
      }
      result->Success();
    } else if (method == "quit") {
      result->Success(); DestroyWindow(window_);
    } else {
      result->NotImplemented();
    }
  });
}

ClipboardBridge::~ClipboardBridge() {
  RemoveClipboardFormatListener(window_);
  if (network_notification_) CancelMibChangeNotify2(network_notification_);
  if (tray_ready_) Shell_NotifyIconW(NIM_DELETE, &tray_);
  channel_->SetMethodCallHandler(nullptr);
}

void ClipboardBridge::Show() {
  ShowWindow(window_, SW_RESTORE);
  SetForegroundWindow(window_);
}
void ClipboardBridge::Action(const char* action) {
  channel_->InvokeMethod("trayAction", std::make_unique<Value>(action));
}

std::optional<LRESULT> ClipboardBridge::Handle(UINT message, WPARAM, LPARAM lparam) {
  if (message == WM_CLIPBOARDUPDATE) {
    channel_->InvokeMethod("clipboardChanged", std::make_unique<Value>()); return 0;
  }
  if (message == kNetworkMessage) {
    channel_->InvokeMethod("networkChanged", std::make_unique<Value>()); return 0;
  }
  if (message == WM_CLOSE && tray_ready_) { ShowWindow(window_, SW_HIDE); return 0; }
  if (message == kTrayMessage) {
    if (lparam == WM_LBUTTONUP || lparam == WM_LBUTTONDBLCLK) Show();
    if (lparam == WM_RBUTTONUP) {
      HMENU menu = CreatePopupMenu();
      AppendMenuW(menu, MF_STRING, 1, L"Open LocalClipboard");
      AppendMenuW(menu, MF_STRING, 2, paused_ ? L"Resume sharing" : L"Pause sharing");
      AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
      AppendMenuW(menu, MF_STRING, 3, L"Quit");
      POINT point; GetCursorPos(&point); SetForegroundWindow(window_);
      const UINT selected = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON,
        point.x, point.y, 0, window_, nullptr);
      DestroyMenu(menu);
      if (selected == 1) Show();
      if (selected == 2) Action("pause");
      if (selected == 3) Action("quit");
    }
    return 0;
  }
  return std::nullopt;
}
