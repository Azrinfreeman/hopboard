#include "virtual_clipboard.h"

#include <ole2.h>
#include <shlobj.h>
#include <shldisp.h>
#include <shobjidl.h>
#include <urlmon.h>

#include <algorithm>
#include <cstring>

namespace {
constexpr UINT kTaskMessage = WM_APP + 1;
// A paste fails when no new bytes arrive for this long (host gone, stalled).
constexpr ULONGLONG kStallMs = 90 * 1000;

UINT Format(const wchar_t* name) { return RegisterClipboardFormatW(name); }

HGLOBAL DwordGlobal(DWORD value) {
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, sizeof(DWORD));
  auto* data = memory ? static_cast<DWORD*>(GlobalLock(memory)) : nullptr;
  if (!data) {
    if (memory) GlobalFree(memory);
    return nullptr;
  }
  *data = value;
  GlobalUnlock(memory);
  return memory;
}

FILETIME FromUnixMs(int64_t ms) {
  ULARGE_INTEGER value;
  value.QuadPart = static_cast<ULONGLONG>(ms) * 10000ULL + 116444736000000000ULL;
  FILETIME time;
  time.dwLowDateTime = value.LowPart;
  time.dwHighDateTime = value.HighPart;
  return time;
}

// Reads one received file, waiting for bytes that are still downloading.
// Called on the OLE STA thread; waits pump COM calls and window messages.
class VirtualStream : public IStream {
 public:
  VirtualStream(std::shared_ptr<VirtualItemState> item, size_t entry)
      : item_(std::move(item)), entry_(entry) {}

  ~VirtualStream() {
    if (file_ != INVALID_HANDLE_VALUE) CloseHandle(file_);
    if (idle_) CloseHandle(idle_);
  }

  // IUnknown
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** out) override {
    if (!out) return E_POINTER;
    if (riid == IID_IUnknown || riid == IID_ISequentialStream ||
        riid == IID_IStream) {
      *out = static_cast<IStream*>(this);
      AddRef();
      return S_OK;
    }
    *out = nullptr;
    return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }
  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG count = --refs_;
    if (count == 0) delete this;
    return count;
  }

  // ISequentialStream
  HRESULT STDMETHODCALLTYPE Read(void* buffer, ULONG wanted,
                                 ULONG* read_out) override {
    if (read_out) *read_out = 0;
    if (!buffer) return STG_E_INVALIDPOINTER;
    const uint64_t size = item_->entries[entry_].size;
    if (position_ >= size || wanted == 0) return S_FALSE;
    const uint64_t want =
        (std::min)(static_cast<uint64_t>(wanted), size - position_);
    std::wstring path;
    // Explorer may treat a short read as the end of the file, so wait for
    // the whole requested range.
    for (;;) {
      {
        std::lock_guard<std::mutex> lock(item_->mutex);
        if (item_->failed) return STG_E_READFAULT;
        const auto& file = item_->files[entry_];
        if (!file.path.empty() &&
            (file.done || file.available >= position_ + want)) {
          path = file.path;
          break;
        }
        if (item_->last_progress &&
            GetTickCount64() - item_->last_progress > kStallMs) {
          item_->failed = true;
          return STG_E_READFAULT;
        }
      }
      DWORD index = 0;
      // A short sleep that still services COM calls and sent messages.
      const HRESULT waited = CoWaitForMultipleHandles(
          COWAIT_DISPATCH_CALLS | COWAIT_DISPATCH_WINDOW_MESSAGES, 15, 1,
          &idle_, &index);
      if (FAILED(waited) && waited != RPC_S_CALLPENDING) return waited;
    }
    if (file_ == INVALID_HANDLE_VALUE) {
      // The finished file can be renamed just before its new path is
      // reported, so retry briefly with the latest path.
      for (int attempt = 0; attempt < 200; ++attempt) {
        // Share delete so Hopboard can rename the finished file under us.
        file_ = CreateFileW(path.c_str(), GENERIC_READ,
                            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                            nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file_ != INVALID_HANDLE_VALUE) break;
        DWORD index = 0;
        CoWaitForMultipleHandles(
            COWAIT_DISPATCH_CALLS | COWAIT_DISPATCH_WINDOW_MESSAGES, 25, 1,
            &idle_, &index);
        std::lock_guard<std::mutex> lock(item_->mutex);
        if (item_->failed) return STG_E_READFAULT;
        path = item_->files[entry_].path;
      }
      if (file_ == INVALID_HANDLE_VALUE) return STG_E_READFAULT;
    }
    LARGE_INTEGER offset;
    offset.QuadPart = static_cast<LONGLONG>(position_);
    if (!SetFilePointerEx(file_, offset, nullptr, FILE_BEGIN)) {
      return STG_E_READFAULT;
    }
    ULONG total = 0;
    auto* bytes = static_cast<uint8_t*>(buffer);
    while (total < want) {
      DWORD chunk = 0;
      if (!ReadFile(file_, bytes + total, static_cast<DWORD>(want - total),
                    &chunk, nullptr)) {
        return STG_E_READFAULT;
      }
      if (chunk == 0) break;
      total += chunk;
    }
    position_ += total;
    if (read_out) *read_out = total;
    return total == 0 ? S_FALSE : S_OK;
  }
  HRESULT STDMETHODCALLTYPE Write(const void*, ULONG, ULONG*) override {
    return STG_E_ACCESSDENIED;
  }

  // IStream
  HRESULT STDMETHODCALLTYPE Seek(LARGE_INTEGER move, DWORD origin,
                                 ULARGE_INTEGER* result) override {
    const int64_t size = static_cast<int64_t>(item_->entries[entry_].size);
    int64_t base = 0;
    if (origin == STREAM_SEEK_CUR) base = static_cast<int64_t>(position_);
    else if (origin == STREAM_SEEK_END) base = size;
    else if (origin != STREAM_SEEK_SET) return STG_E_INVALIDFUNCTION;
    const int64_t target = base + move.QuadPart;
    if (target < 0) return STG_E_INVALIDFUNCTION;
    position_ = static_cast<uint64_t>(target);
    if (result) result->QuadPart = position_;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE SetSize(ULARGE_INTEGER) override {
    return STG_E_ACCESSDENIED;
  }
  HRESULT STDMETHODCALLTYPE CopyTo(IStream*, ULARGE_INTEGER, ULARGE_INTEGER*,
                                   ULARGE_INTEGER*) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE Commit(DWORD) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE Revert() override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE LockRegion(ULARGE_INTEGER, ULARGE_INTEGER,
                                       DWORD) override {
    return STG_E_INVALIDFUNCTION;
  }
  HRESULT STDMETHODCALLTYPE UnlockRegion(ULARGE_INTEGER, ULARGE_INTEGER,
                                         DWORD) override {
    return STG_E_INVALIDFUNCTION;
  }
  HRESULT STDMETHODCALLTYPE Stat(STATSTG* stat, DWORD flags) override {
    if (!stat) return STG_E_INVALIDPOINTER;
    ZeroMemory(stat, sizeof(*stat));
    stat->type = STGTY_STREAM;
    stat->cbSize.QuadPart = item_->entries[entry_].size;
    stat->grfMode = STGM_READ;
    if (!(flags & STATFLAG_NONAME)) {
      const auto& path = item_->entries[entry_].path;
      const auto slash = path.find_last_of(L'\\');
      const std::wstring name =
          slash == std::wstring::npos ? path : path.substr(slash + 1);
      const size_t bytes = (name.size() + 1) * sizeof(wchar_t);
      stat->pwcsName = static_cast<LPOLESTR>(CoTaskMemAlloc(bytes));
      if (!stat->pwcsName) return E_OUTOFMEMORY;
      memcpy(stat->pwcsName, name.c_str(), bytes);
    }
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE Clone(IStream**) override { return E_NOTIMPL; }

 private:
  std::atomic<ULONG> refs_{1};
  std::shared_ptr<VirtualItemState> item_;
  size_t entry_;
  uint64_t position_ = 0;
  HANDLE file_ = INVALID_HANDLE_VALUE;
  // Never signalled: the wait is only a message-pumping sleep.
  HANDLE idle_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
};

class VirtualDataObject : public IDataObject, public IDataObjectAsyncCapability {
 public:
  VirtualDataObject(std::shared_ptr<VirtualItemState> item,
                    VirtualClipboard::Requested requested)
      : item_(std::move(item)), requested_(std::move(requested)) {
    descriptor_ = Format(CFSTR_FILEDESCRIPTORW);
    contents_ = Format(CFSTR_FILECONTENTS);
    effect_ = Format(CFSTR_PREFERREDDROPEFFECT);
    history_ = Format(L"CanIncludeInClipboardHistory");
    cloud_ = Format(L"CanUploadToCloudClipboard");
    marker_ = VirtualClipboard::MarkerFormat();
    zone_ = Format(CFSTR_ZONEIDENTIFIER);
  }

  // IUnknown
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** out) override {
    if (!out) return E_POINTER;
    if (riid == IID_IUnknown || riid == IID_IDataObject) {
      *out = static_cast<IDataObject*>(this);
    } else if (riid == __uuidof(IDataObjectAsyncCapability)) {
      *out = static_cast<IDataObjectAsyncCapability*>(this);
    } else {
      *out = nullptr;
      return E_NOINTERFACE;
    }
    AddRef();
    return S_OK;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }
  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG count = --refs_;
    if (count == 0) delete this;
    return count;
  }

  // IDataObject
  HRESULT STDMETHODCALLTYPE GetData(FORMATETC* format,
                                    STGMEDIUM* medium) override {
    if (!format || !medium) return E_INVALIDARG;
    ZeroMemory(medium, sizeof(*medium));
    const CLIPFORMAT cf = format->cfFormat;
    if (cf == contents_) {
      if (!(format->tymed & TYMED_ISTREAM)) return DV_E_TYMED;
      if (format->lindex < 0 ||
          static_cast<size_t>(format->lindex) >= item_->entries.size() ||
          item_->entries[format->lindex].directory) {
        return DV_E_LINDEX;
      }
      {
        std::lock_guard<std::mutex> lock(item_->mutex);
        if (item_->failed) return E_FAIL;
        if (!item_->requested) {
          item_->requested = true;
          item_->last_progress = GetTickCount64();
          if (requested_) requested_(item_->id);
        }
      }
      medium->tymed = TYMED_ISTREAM;
      medium->pstm = new VirtualStream(item_, format->lindex);
      return S_OK;
    }
    if (!(format->tymed & TYMED_HGLOBAL)) return DV_E_TYMED;
    HGLOBAL memory = nullptr;
    if (cf == descriptor_) {
      memory = Descriptors();
    } else if (cf == effect_) {
      memory = DwordGlobal(DROPEFFECT_COPY);
    } else if (cf == history_ || cf == cloud_) {
      memory = DwordGlobal(0);
    } else if (cf == marker_) {
      memory = DwordGlobal(1);
    } else if (cf == zone_) {
      // Pasted files get the same Mark of the Web as downloaded ones, so
      // SmartScreen and Protected View still apply.
      memory = DwordGlobal(URLZONE_INTERNET);
    } else {
      return DV_E_FORMATETC;
    }
    if (!memory) return E_OUTOFMEMORY;
    medium->tymed = TYMED_HGLOBAL;
    medium->hGlobal = memory;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetDataHere(FORMATETC*, STGMEDIUM*) override {
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE QueryGetData(FORMATETC* format) override {
    if (!format) return E_INVALIDARG;
    const CLIPFORMAT cf = format->cfFormat;
    if (cf == contents_) {
      return format->tymed & TYMED_ISTREAM ? S_OK : DV_E_TYMED;
    }
    if (cf == descriptor_ || cf == effect_ || cf == history_ || cf == cloud_ ||
        cf == marker_ || cf == zone_) {
      return format->tymed & TYMED_HGLOBAL ? S_OK : DV_E_TYMED;
    }
    return DV_E_FORMATETC;
  }
  HRESULT STDMETHODCALLTYPE GetCanonicalFormatEtc(FORMATETC*,
                                                  FORMATETC* out) override {
    if (out) out->ptd = nullptr;
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE SetData(FORMATETC*, STGMEDIUM* medium,
                                    BOOL release) override {
    // Explorer reports "Performed DropEffect" and "Paste Succeeded" here.
    if (release && medium) ReleaseStgMedium(medium);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE EnumFormatEtc(DWORD direction,
                                          IEnumFORMATETC** out) override {
    if (!out) return E_POINTER;
    if (direction != DATADIR_GET) return E_NOTIMPL;
    FORMATETC formats[] = {
        {static_cast<CLIPFORMAT>(descriptor_), nullptr, DVASPECT_CONTENT, -1,
         TYMED_HGLOBAL},
        {static_cast<CLIPFORMAT>(contents_), nullptr, DVASPECT_CONTENT, -1,
         TYMED_ISTREAM},
        {static_cast<CLIPFORMAT>(effect_), nullptr, DVASPECT_CONTENT, -1,
         TYMED_HGLOBAL},
        {static_cast<CLIPFORMAT>(history_), nullptr, DVASPECT_CONTENT, -1,
         TYMED_HGLOBAL},
        {static_cast<CLIPFORMAT>(cloud_), nullptr, DVASPECT_CONTENT, -1,
         TYMED_HGLOBAL},
        {static_cast<CLIPFORMAT>(marker_), nullptr, DVASPECT_CONTENT, -1,
         TYMED_HGLOBAL},
        {static_cast<CLIPFORMAT>(zone_), nullptr, DVASPECT_CONTENT, -1,
         TYMED_HGLOBAL},
    };
    return SHCreateStdEnumFmtEtc(ARRAYSIZE(formats), formats, out);
  }
  HRESULT STDMETHODCALLTYPE DAdvise(FORMATETC*, DWORD, IAdviseSink*,
                                    DWORD*) override {
    return OLE_E_ADVISENOTSUPPORTED;
  }
  HRESULT STDMETHODCALLTYPE DUnadvise(DWORD) override {
    return OLE_E_ADVISENOTSUPPORTED;
  }
  HRESULT STDMETHODCALLTYPE EnumDAdvise(IEnumSTATDATA**) override {
    return OLE_E_ADVISENOTSUPPORTED;
  }

  // IDataObjectAsyncCapability: lets Explorer copy on a background thread
  // instead of freezing while bytes stream in.
  HRESULT STDMETHODCALLTYPE SetAsyncMode(BOOL async) override {
    async_ = async;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetAsyncMode(BOOL* async) override {
    if (!async) return E_POINTER;
    *async = async_;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE StartOperation(IBindCtx*) override {
    in_operation_ = TRUE;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE InOperation(BOOL* in_operation) override {
    if (!in_operation) return E_POINTER;
    *in_operation = in_operation_;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE EndOperation(HRESULT, IBindCtx*, DWORD) override {
    in_operation_ = FALSE;
    return S_OK;
  }

 private:
  HGLOBAL Descriptors() const {
    const auto& entries = item_->entries;
    const size_t bytes =
        sizeof(FILEGROUPDESCRIPTORW) +
        (entries.empty() ? 0 : (entries.size() - 1) * sizeof(FILEDESCRIPTORW));
    HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, bytes);
    auto* group =
        memory ? static_cast<FILEGROUPDESCRIPTORW*>(GlobalLock(memory)) : nullptr;
    if (!group) {
      if (memory) GlobalFree(memory);
      return nullptr;
    }
    group->cItems = static_cast<UINT>(entries.size());
    for (size_t i = 0; i < entries.size(); ++i) {
      const auto& entry = entries[i];
      auto& descriptor = group->fgd[i];
      descriptor.dwFlags = static_cast<DWORD>(FD_ATTRIBUTES | FD_UNICODE | FD_PROGRESSUI);
      descriptor.dwFileAttributes =
          entry.directory ? FILE_ATTRIBUTE_DIRECTORY : FILE_ATTRIBUTE_NORMAL;
      if (!entry.directory) {
        descriptor.dwFlags |= static_cast<DWORD>(FD_FILESIZE);
        descriptor.nFileSizeHigh = static_cast<DWORD>(entry.size >> 32);
        descriptor.nFileSizeLow = static_cast<DWORD>(entry.size & 0xffffffff);
      }
      if (entry.mtime >= 0) {
        descriptor.dwFlags |= static_cast<DWORD>(FD_WRITESTIME);
        descriptor.ftLastWriteTime = FromUnixMs(entry.mtime);
      }
      wcsncpy_s(descriptor.cFileName, entry.path.c_str(), _TRUNCATE);
    }
    GlobalUnlock(memory);
    return memory;
  }

  std::atomic<ULONG> refs_{1};
  std::shared_ptr<VirtualItemState> item_;
  VirtualClipboard::Requested requested_;
  UINT descriptor_, contents_, effect_, history_, cloud_, marker_, zone_;
  BOOL async_ = TRUE;
  BOOL in_operation_ = FALSE;
};
}  // namespace

UINT VirtualClipboard::MarkerFormat() {
  static const UINT format = Format(L"Hopboard.VirtualFiles");
  return format;
}

VirtualClipboard::VirtualClipboard(Requested requested)
    : requested_(std::move(requested)) {
  ready_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  thread_ = std::thread([this] { Run(); });
  if (ready_) WaitForSingleObject(ready_, 5000);
}

VirtualClipboard::~VirtualClipboard() {
  const DWORD id = thread_id_.load();
  if (id) PostThreadMessageW(id, WM_QUIT, 0, 0);
  if (thread_.joinable()) thread_.join();
  if (ready_) CloseHandle(ready_);
}

void VirtualClipboard::Run() {
  const HRESULT initialized = OleInitialize(nullptr);
  MSG message;
  // Create the thread's message queue before announcing it.
  PeekMessageW(&message, nullptr, WM_USER, WM_USER, PM_NOREMOVE);
  thread_id_ = GetCurrentThreadId();
  if (ready_) SetEvent(ready_);
  while (GetMessageW(&message, nullptr, 0, 0) > 0) {
    if (message.hwnd == nullptr && message.message == kTaskMessage) {
      std::deque<std::function<void()>> tasks;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        tasks.swap(tasks_);
      }
      for (auto& task : tasks) task();
      continue;
    }
    TranslateMessage(&message);
    DispatchMessageW(&message);
  }
  // Virtual files cannot outlive the app. Never flush (that would try to
  // render every format); just take them off the clipboard.
  if (object_) {
    if (OleIsCurrentClipboard(object_) == S_OK) OleSetClipboard(nullptr);
    object_->Release();
    object_ = nullptr;
  }
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (current_) {
      std::lock_guard<std::mutex> item_lock(current_->mutex);
      current_->failed = true;
    }
  }
  if (SUCCEEDED(initialized)) OleUninitialize();
}

void VirtualClipboard::Post(std::function<void()> task) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    tasks_.push_back(std::move(task));
  }
  const DWORD id = thread_id_.load();
  if (id) PostThreadMessageW(id, kTaskMessage, 0, 0);
}

std::shared_ptr<VirtualItemState> VirtualClipboard::Find(const std::string& id) {
  std::lock_guard<std::mutex> lock(mutex_);
  for (auto it = recent_.begin(); it != recent_.end();) {
    auto item = it->lock();
    if (!item) {
      it = recent_.erase(it);
      continue;
    }
    if (item->id == id) return item;
    ++it;
  }
  return nullptr;
}

void VirtualClipboard::Write(std::shared_ptr<VirtualItemState> item,
                             int64_t expected_revision, WriteDone done) {
  {
    std::lock_guard<std::mutex> lock(item->mutex);
    item->files.assign(item->entries.size(), {});
  }
  Post([this, item, expected_revision, done] {
    if (expected_revision >= 0 &&
        expected_revision != static_cast<int64_t>(GetClipboardSequenceNumber())) {
      done(0, 0);
      return;
    }
    auto* object = new VirtualDataObject(item, requested_);
    HRESULT result = E_FAIL;
    // Another app may hold the clipboard open for a moment.
    for (int attempt = 0; attempt < 5; ++attempt) {
      result = OleSetClipboard(object);
      if (result != CLIPBRD_E_CANT_OPEN) break;
      Sleep(20 * (attempt + 1));
    }
    if (FAILED(result)) {
      object->Release();
      done(result == CLIPBRD_E_CANT_OPEN ? -1 : -2, 0);
      return;
    }
    if (object_) object_->Release();
    object_ = object;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      // A paste of the previous item can still finish from its own state.
      current_ = item;
      recent_.push_back(item);
      if (recent_.size() > 8) recent_.erase(recent_.begin());
    }
    done(1, static_cast<int64_t>(GetClipboardSequenceNumber()));
  });
}

bool VirtualClipboard::Progress(const std::string& id, size_t entry,
                                const std::wstring* path, uint64_t available,
                                bool done, bool failed) {
  const auto item = Find(id);
  if (!item) return false;
  std::lock_guard<std::mutex> lock(item->mutex);
  item->last_progress = GetTickCount64();
  if (failed) {
    item->failed = true;
    return true;
  }
  if (entry >= item->files.size()) return false;
  auto& file = item->files[entry];
  if (path) file.path = *path;
  file.available = (std::max)(file.available, available);
  file.done = file.done || done;
  return true;
}

void VirtualClipboard::Clear(const std::string& id,
                             std::function<void(bool)> done) {
  if (const auto item = Find(id)) {
    std::lock_guard<std::mutex> lock(item->mutex);
    item->failed = true;
  }
  Post([this, id, done] {
    bool cleared = false;
    std::shared_ptr<VirtualItemState> current;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      current = current_;
    }
    if (object_ && current && current->id == id &&
        OleIsCurrentClipboard(object_) == S_OK) {
      cleared = SUCCEEDED(OleSetClipboard(nullptr));
    }
    done(cleared);
  });
}

bool VirtualClipboard::IsCurrent(const std::string& id) {
  std::lock_guard<std::mutex> lock(mutex_);
  return current_ && current_->id == id;
}
