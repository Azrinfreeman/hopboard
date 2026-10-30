#include <winsock2.h>
#include <ws2ipdef.h>
#include "clipboard_bridge.h"
#include <iphlpapi.h>
#include <netioapi.h>
#include <wincrypt.h>
#include <shlobj.h>
#include <sddl.h>
#include <vector>
#include <algorithm>
#include <string>
#include <cstring>
#include <thread>
#include "clipboard_image.h"
#include "updater.h"
#include "resource.h"

struct ClipboardImageJob {
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result;
  flutter::EncodableMap data;
  ClipboardImage image;
  PreparedClipboardImage prepared;
  std::string error;
  std::optional<std::string> text;
  int64_t expected = -1;
  bool writing = false;
  uint64_t generation = 0;
};

namespace {
constexpr UINT kTrayMessage = WM_APP + 41;
constexpr UINT kNetworkMessage = WM_APP + 42;
constexpr UINT kImageMessage = WM_APP + 43;
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
        if (!CryptProtectData(&input, L"Hopboard", nullptr, nullptr, nullptr,
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
      wcscpy_s(tray_.szTip, L"Hopboard");
      tray_ready_ = Shell_NotifyIconW(NIM_ADD, &tray_) != FALSE;
      NotifyIpInterfaceChange(AF_INET, NetworkChanged, window_, FALSE,
        &network_notification_);
      result->Success();
      DragAcceptFiles(window_, TRUE);
    } else if (method == "readClipboard") {
      const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      const bool include_image = args && args->count(Value("includeImage")) &&
        std::get_if<bool>(&args->at(Value("includeImage"))) &&
        std::get<bool>(args->at(Value("includeImage")));
      if (include_image && image_job_) {
        result->Error("busy", "Image conversion is in progress."); return;
      }
      if (!OpenClipboard(window_)) {
        result->Error("busy", "Clipboard is temporarily busy."); return;
      }
      Map data;
      const DWORD revision = GetClipboardSequenceNumber();
      data[Value("revision")] = Value(static_cast<int64_t>(revision));
      data[Value("ownWrite")] = Value(revision != 0 && revision == own_revision_);
      data[Value("sensitive")] = Value(IsPrivateClipboard());
      const bool has_files = IsClipboardFormatAvailable(CF_HDROP) != FALSE;
      data[Value("hasFiles")] = Value(has_files);
      const UINT png_format = RegisterClipboardFormatW(L"PNG");
      const UINT image_format = IsClipboardFormatAvailable(png_format) ? png_format :
        IsClipboardFormatAvailable(CF_DIBV5) ? CF_DIBV5 :
        IsClipboardFormatAvailable(CF_DIB) ? CF_DIB : 0;
      data[Value("hasImage")] = Value(image_format != 0 && !has_files);
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
      const bool include_files = args && args->count(Value("includeFiles")) &&
        std::get_if<bool>(&args->at(Value("includeFiles"))) && std::get<bool>(args->at(Value("includeFiles")));
      if (include_files && has_files) {
        flutter::EncodableList paths;
        const auto drop = static_cast<HDROP>(GetClipboardData(CF_HDROP));
        const UINT count = drop ? DragQueryFileW(drop, 0xffffffff, nullptr, 0) : 0;
        if (count > 5000) { CloseClipboard(); result->Error("files", "Too many files."); return; }
        for (UINT i = 0; i < count; ++i) {
          const UINT length = DragQueryFileW(drop, i, nullptr, 0);
          std::wstring path(length + 1, L'\0');
          DragQueryFileW(drop, i, path.data(), length + 1);
          path.resize(length);
          paths.emplace_back(Utf8(path));
        }
        data[Value("filePaths")] = Value(paths);
        const UINT effect = RegisterClipboardFormatW(L"Preferred DropEffect");
        const HANDLE handle = GetClipboardData(effect);
        const auto* value = handle && GlobalSize(handle) >= sizeof(DWORD) ? static_cast<const DWORD*>(GlobalLock(handle)) : nullptr;
        data[Value("cut")] = Value(value && (*value & DROPEFFECT_MOVE) != 0);
        if (value) GlobalUnlock(handle);
      }
      std::vector<uint8_t> image;
      if (include_image && image_format && !has_files) {
        const HANDLE pixels = GetClipboardData(image_format);
        const SIZE_T size = pixels ? GlobalSize(pixels) : 0;
        const SIZE_T limit = image_format == png_format ? 16 * 1024 * 1024 : 202 * 1024 * 1024;
        const auto* bytes = size && size <= limit ? static_cast<const uint8_t*>(GlobalLock(pixels)) : nullptr;
        if (bytes) {
          image.assign(bytes, bytes + size);
          GlobalUnlock(pixels);
        }
      }
      CloseClipboard();
      if (include_image && image_format && !has_files) {
        if (image.empty()) { result->Error("image", "The image is unavailable or exceeds the image limit."); return; }
        image_job_ = std::make_shared<ClipboardImageJob>();
        image_job_->result = std::move(result);
        image_job_->data = std::move(data);
        const auto job = image_job_;
        const HWND window = window_;
        image_worker_ = std::thread([job, window, image_format, bytes = std::move(image)]() {
          const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
          try { job->image = ConvertClipboardImage(image_format, bytes); }
          catch (const std::exception& error) { job->error = error.what(); }
          if (SUCCEEDED(initialized)) CoUninitialize();
          PostMessageW(window, kImageMessage, 0, 0);
        });
      } else {
        result->Success(Value(data));
      }
    } else if (method == "readImageChunk") {
      const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      const auto* token = StringArg(args, "token");
      const int64_t offset = args && args->count(Value("offset")) ? Integer(args->at(Value("offset"))) : -1;
      if (!token || *token != image_token_ || offset < 0 || static_cast<size_t>(offset) >= image_bytes_.size()) {
        result->Error("image", "The clipboard image changed. Copy it again."); return;
      }
      const auto end = (std::min)(image_bytes_.size(), static_cast<size_t>(offset) + 65536);
      result->Success(Value(std::vector<uint8_t>(image_bytes_.begin() + offset, image_bytes_.begin() + end)));
    } else if (method == "releaseImageRead") {
      const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      const auto* token = StringArg(args, "token");
      if (token && *token == image_token_) {
        SecureZeroMemory(image_bytes_.data(), image_bytes_.size());
        std::vector<uint8_t>().swap(image_bytes_);
        image_token_.clear();
      }
      result->Success();
    } else if (method == "cancelImageWrite") {
      image_write_generation_++;
      SecureZeroMemory(write_image_.data(), write_image_.size());
      std::vector<uint8_t>().swap(write_image_);
      write_token_.clear();
      result->Success();
    } else if (method == "beginImageWrite") {
      const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      const int64_t size = args && args->count(Value("size")) ? Integer(args->at(Value("size"))) : -1;
      if (image_job_ || size < 33 || size > 16 * 1024 * 1024) {
        result->Error("busy", "Image clipboard is busy or the image exceeds 16 MiB."); return;
      }
      write_image_.clear();
      write_size_ = static_cast<size_t>(size);
      write_token_ = std::to_string(++image_serial_);
      write_image_.reserve(write_size_);
      result->Success(Value(write_token_));
    } else if (method == "appendImageWrite") {
      const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      const auto* token = StringArg(args, "token");
      const auto* bytes = args && args->count(Value("bytes")) ?
        std::get_if<std::vector<uint8_t>>(&args->at(Value("bytes"))) : nullptr;
      if (!token || *token != write_token_ || !bytes || bytes->size() > 65536 ||
          write_image_.size() + bytes->size() > write_size_) {
        result->Error("image", "Invalid image chunk."); return;
      }
      write_image_.insert(write_image_.end(), bytes->begin(), bytes->end());
      result->Success();
    } else if (method == "finishImageWrite") {
      const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      const auto* token = StringArg(args, "token");
      const auto* text = StringArg(args, "text");
      if (!token || *token != write_token_ || image_job_ || write_image_.size() != write_size_ ||
          (text && (text->size() > 65536 || text->find('\0') != std::string::npos))) {
        result->Error("image", "Image write is incomplete or busy."); return;
      }
      image_job_ = std::make_shared<ClipboardImageJob>();
      image_job_->result = std::move(result);
      image_job_->writing = true;
      image_job_->generation = image_write_generation_;
      if (text) image_job_->text = *text;
      if (args->count(Value("expectedRevision"))) image_job_->expected = Integer(args->at(Value("expectedRevision")));
      const auto job = image_job_;
      const HWND window = window_;
      write_token_.clear();
      image_worker_ = std::thread([job, window, bytes = std::move(write_image_)]() {
        const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        try { PrepareClipboardImage(bytes, job->prepared); }
        catch (const std::exception& error) { job->error = error.what(); }
        if (SUCCEEDED(initialized)) CoUninitialize();
        PostMessageW(window, kImageMessage, 0, 0);
      });
    } else if (method == "pickFiles" || method == "pickFolder") {
      IFileOpenDialog* dialog = nullptr;
      if (FAILED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog)))) {
        result->Error("files", "File picker unavailable."); return;
      }
      DWORD options = 0; dialog->GetOptions(&options);
      dialog->SetOptions(options | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST | FOS_FILEMUSTEXIST |
          (method == "pickFolder" ? FOS_PICKFOLDERS : FOS_ALLOWMULTISELECT));
      const HRESULT shown = dialog->Show(window_);
      flutter::EncodableList paths;
      if (SUCCEEDED(shown)) {
        IShellItemArray* items = nullptr;
        if (SUCCEEDED(dialog->GetResults(&items))) {
          DWORD count = 0; items->GetCount(&count);
          for (DWORD i = 0; i < count; ++i) {
            IShellItem* item = nullptr;
            if (SUCCEEDED(items->GetItemAt(i, &item))) {
              PWSTR path = nullptr;
              if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path))) {
                paths.emplace_back(Utf8(path)); CoTaskMemFree(path);
              }
              item->Release();
            }
          }
          items->Release();
        }
      }
      dialog->Release();
      if (FAILED(shown) && shown != HRESULT_FROM_WIN32(ERROR_CANCELLED)) result->Error("files", "File picker failed.");
      else result->Success(Value(paths));
    } else if (method == "showReceivedFolder") {
      const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      const auto* path = StringArg(args, "path");
      const auto wide = path ? Wide(*path) : std::wstring();
      const DWORD attrs = wide.empty() ? INVALID_FILE_ATTRIBUTES : GetFileAttributesW(wide.c_str());
      if (attrs == INVALID_FILE_ATTRIBUTES || !(attrs & FILE_ATTRIBUTE_DIRECTORY) || (attrs & FILE_ATTRIBUTE_REPARSE_POINT)) {
        result->Error("files", "Received folder unavailable."); return;
      }
      ShellExecuteW(window_, L"open", L"explorer.exe", (L"\"" + wide + L"\"").c_str(), nullptr, SW_SHOWNORMAL);
      result->Success();
    } else if (method == "inspectFile") {
      const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      const auto* path = StringArg(args, "path");
      if (!path) { result->Error("files", "Missing path."); return; }
      auto wide = Wide(*path);
      // Reject network shares, device paths, links, and cloud placeholders.
      if (wide.size() < 3 || wide[1] != L':' || wide[2] != L'\\') {
        result->Error("files", "Only local files are supported."); return;
      }
      bool valid = true;
      for (size_t end = 3; end <= wide.size(); ++end) {
        if (end != wide.size() && wide[end] != L'\\') continue;
        const DWORD attrs = GetFileAttributesW(wide.substr(0, end).c_str());
        if (attrs == INVALID_FILE_ATTRIBUTES ||
            (attrs & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_OFFLINE | FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS | FILE_ATTRIBUTE_RECALL_ON_OPEN))) { valid = false; break; }
      }
      if (valid) result->Success();
      else result->Error("files", "Links, cloud placeholders and unavailable files cannot be shared.");
    } else if (method == "availableFileSpace") {
      const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      const auto* path = StringArg(args, "path");
      const auto wide = path ? Wide(*path) : std::wstring();
      ULARGE_INTEGER available{};
      if (wide.empty() || !GetDiskFreeSpaceExW(wide.c_str(), &available, nullptr, nullptr)) {
        result->Error("files", "Available disk space could not be checked."); return;
      }
      result->Success(Value(static_cast<int64_t>(available.QuadPart)));
    } else if (method == "receiveCache") {
      PWSTR local = nullptr;
      if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &local))) {
        result->Error("files", "Local storage unavailable."); return;
      }
      const std::wstring base = std::wstring(local) + L"\\Hopboard";
      CoTaskMemFree(local);
      PSECURITY_DESCRIPTOR descriptor = nullptr;
      if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
          L"D:P(A;OICI;FA;;;OW)(A;OICI;FA;;;SY)", SDDL_REVISION_1, &descriptor, nullptr)) {
        result->Error("files", "Private storage unavailable."); return;
      }
      SECURITY_ATTRIBUTES security{sizeof(SECURITY_ATTRIBUTES), descriptor, FALSE};
      bool ok = true;
      const std::wstring cache = base + L"\\Received";
      for (const auto& path : {base, cache}) {
        if (!CreateDirectoryW(path.c_str(), &security) && GetLastError() != ERROR_ALREADY_EXISTS) { ok = false; break; }
        const DWORD attrs = GetFileAttributesW(path.c_str());
        if (attrs == INVALID_FILE_ATTRIBUTES || !(attrs & FILE_ATTRIBUTE_DIRECTORY) || (attrs & FILE_ATTRIBUTE_REPARSE_POINT) ||
            !SetFileSecurityW(path.c_str(), DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION, descriptor)) { ok = false; break; }
      }
      LocalFree(descriptor);
      if (ok) SetFileAttributesW(cache.c_str(), FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_NOT_CONTENT_INDEXED);
      if (ok) result->Success(Value(Utf8(cache)));
      else result->Error("files", "Private receive cache unavailable.");
    } else if (method == "writeFiles") {
      const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      const auto* paths = args && args->count(Value("paths")) ? std::get_if<flutter::EncodableList>(&args->at(Value("paths"))) : nullptr;
      if (!paths || paths->empty() || paths->size() > 5000) { result->Error("files", "Invalid file list."); return; }
      std::wstring names;
      for (const auto& value : *paths) {
        const auto* path = std::get_if<std::string>(&value);
        if (!path || path->find('\0') != std::string::npos) { result->Error("files", "Invalid path."); return; }
        names += Wide(*path); names.push_back(L'\0');
      }
      names.push_back(L'\0');
      HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, sizeof(DROPFILES) + names.size() * sizeof(wchar_t));
      HGLOBAL effect = GlobalAlloc(GMEM_MOVEABLE, sizeof(DWORD));
      auto* drop = memory ? static_cast<DROPFILES*>(GlobalLock(memory)) : nullptr;
      auto* effect_value = effect ? static_cast<DWORD*>(GlobalLock(effect)) : nullptr;
      if (!drop || !effect_value) {
        if (drop) GlobalUnlock(memory); if (effect_value) GlobalUnlock(effect);
        if (memory) GlobalFree(memory); if (effect) GlobalFree(effect);
        result->Error("files", "Clipboard allocation failed."); return;
      }
      drop->pFiles = sizeof(DROPFILES); drop->fWide = TRUE;
      memcpy(reinterpret_cast<uint8_t*>(drop) + sizeof(DROPFILES), names.data(), names.size() * sizeof(wchar_t));
      *effect_value = DROPEFFECT_COPY;
      GlobalUnlock(memory); GlobalUnlock(effect);
      if (!OpenClipboard(window_)) { GlobalFree(memory); GlobalFree(effect); result->Error("busy", "Clipboard is busy."); return; }
      const auto expected = args->find(Value("expectedRevision"));
      if (expected != args->end() && Integer(expected->second) >= 0 && Integer(expected->second) != GetClipboardSequenceNumber()) {
        CloseClipboard(); GlobalFree(memory); GlobalFree(effect); result->Success(Value(false)); return;
      }
      bool ok = EmptyClipboard() && SetClipboardData(CF_HDROP, memory);
      if (!ok) GlobalFree(memory);
      if (!ok || !SetClipboardData(RegisterClipboardFormatW(L"Preferred DropEffect"), effect)) { GlobalFree(effect); ok = false; }
      if (ok) { ExcludeFromHistory(); own_revision_ = GetClipboardSequenceNumber(); }
      CloseClipboard(); result->Success(Value(ok));
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
      const auto tip = Wide("Hopboard - " + *status);
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
    } else if (method == "updateDirectory") {
      const auto directory = UpdateDirectory();
      if (directory.empty()) result->Error("update", "Update folder is unavailable.");
      else result->Success(Value(Utf8(directory)));
    } else if (method == "installUpdate") {
      const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      const auto* path = StringArg(args, "path");
      const auto* hash = StringArg(args, "sha256");
      if (!path || !hash || !LaunchUpdate(Wide(*path), Wide(*hash))) {
        result->Error("update", "Installer verification failed or the installer could not start."); return;
      }
      result->Success();
      DestroyWindow(window_);
    } else if (method == "quit") {
      result->Success(); DestroyWindow(window_);
    } else {
      result->NotImplemented();
    }
  });
}

ClipboardBridge::~ClipboardBridge() {
  if (image_worker_.joinable()) image_worker_.join();
  RemoveClipboardFormatListener(window_);
  if (network_notification_) CancelMibChangeNotify2(network_notification_);
  if (tray_ready_) Shell_NotifyIconW(NIM_DELETE, &tray_);
  channel_->SetMethodCallHandler(nullptr);
}

void ClipboardBridge::CompleteImage() {
  if (!image_job_) return;
  if (image_worker_.joinable()) image_worker_.join();
  const auto job = std::move(image_job_);
  if (job->writing && job->generation != image_write_generation_) {
    job->result->Success(Value(false)); return;
  }
  if (!job->error.empty()) { job->result->Error("image", job->error); return; }
  if (!job->writing) {
    image_bytes_ = std::move(job->image.png);
    image_token_ = std::to_string(++image_serial_);
    job->data[Value("imageToken")] = Value(image_token_);
    job->data[Value("imageSize")] = Value(static_cast<int64_t>(image_bytes_.size()));
    job->data[Value("width")] = Value(static_cast<int64_t>(job->image.width));
    job->data[Value("height")] = Value(static_cast<int64_t>(job->image.height));
    job->result->Success(Value(job->data));
    return;
  }
  HGLOBAL text = nullptr;
  if (job->text) {
    const auto wide = Wide(*job->text);
    text = GlobalAlloc(GMEM_MOVEABLE, (wide.size() + 1) * sizeof(wchar_t));
    void* buffer = text ? GlobalLock(text) : nullptr;
    if (!buffer) { if (text) GlobalFree(text); job->result->Error("memory", "Clipboard allocation failed."); return; }
    memcpy(buffer, wide.c_str(), (wide.size() + 1) * sizeof(wchar_t));
    GlobalUnlock(text);
  }
  if (!OpenClipboard(window_)) {
    if (text) GlobalFree(text);
    job->result->Error("busy", "Clipboard is temporarily busy."); return;
  }
  if (job->expected >= 0 && job->expected != static_cast<int64_t>(GetClipboardSequenceNumber())) {
    CloseClipboard(); if (text) GlobalFree(text); job->result->Success(Value(false)); return;
  }
  bool success = EmptyClipboard() != FALSE;
  if (success && text) {
    if (SetClipboardData(CF_UNICODETEXT, text)) text = nullptr;
    else success = false;
  }
  if (success) {
    if (SetClipboardData(RegisterClipboardFormatW(L"PNG"), job->prepared.png)) job->prepared.png = nullptr;
    else success = false;
  }
  if (success) {
    if (SetClipboardData(CF_DIBV5, job->prepared.dib)) job->prepared.dib = nullptr;
    else success = false;
  }
  ExcludeFromHistory();
  own_revision_ = GetClipboardSequenceNumber();
  CloseClipboard();
  if (text) GlobalFree(text);
  if (success) job->result->Success(Value(true));
  else job->result->Error("clipboard", "Could not write all clipboard formats.");
}

void ClipboardBridge::Show() {
  ShowWindow(window_, SW_RESTORE);
  SetForegroundWindow(window_);
}
void ClipboardBridge::Action(const char* action) {
  channel_->InvokeMethod("trayAction", std::make_unique<Value>(action));
}

std::optional<LRESULT> ClipboardBridge::Handle(UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_DROPFILES) {
    const auto drop = reinterpret_cast<HDROP>(wparam);
    flutter::EncodableList paths;
    const UINT count = DragQueryFileW(drop, 0xffffffff, nullptr, 0);
    if (count <= 5000) for (UINT i = 0; i < count; ++i) {
      const UINT length = DragQueryFileW(drop, i, nullptr, 0);
      std::wstring path(length + 1, L'\0');
      DragQueryFileW(drop, i, path.data(), length + 1); path.resize(length);
      paths.emplace_back(Utf8(path));
    }
    DragFinish(drop);
    channel_->InvokeMethod("droppedFiles", std::make_unique<Value>(paths));
    return 0;
  }
  if (message == kImageMessage) { CompleteImage(); return 0; }
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
      AppendMenuW(menu, MF_STRING, 1, L"Open Hopboard");
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
