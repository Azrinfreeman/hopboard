#ifndef LOCALCLIPBOARD_VIRTUAL_CLIPBOARD_H_
#define LOCALCLIPBOARD_VIRTUAL_CLIPBOARD_H_

// Virtual files on the Windows clipboard: received files are announced
// immediately with CFSTR_FILEDESCRIPTORW and their bytes are streamed through
// CFSTR_FILECONTENTS while Hopboard downloads them. The OLE data object lives
// on its own STA thread so a paste waiting for bytes never blocks the Flutter
// platform thread.

#include <windows.h>

#include <atomic>
#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

struct VirtualEntry {
  std::wstring path;  // relative, backslash separated
  uint64_t size = 0;
  bool directory = false;
  int64_t mtime = -1;  // milliseconds since the Unix epoch, or -1
};

// Shared between the OLE thread (streams) and the platform thread (progress).
struct VirtualItemState {
  struct File {
    std::wstring path;  // where the bytes currently are on disk
    uint64_t available = 0;
    bool done = false;
  };
  std::string id;
  std::vector<VirtualEntry> entries;
  std::mutex mutex;
  std::vector<File> files;  // parallel to entries
  bool failed = false;
  bool requested = false;
  ULONGLONG last_progress = 0;  // GetTickCount64 of the last update
};

class VirtualClipboard {
 public:
  // Status passed to WriteDone: 1 written, 0 clipboard changed, -1 busy,
  // -2 failed.
  using WriteDone = std::function<void(int status, int64_t revision)>;
  using Requested = std::function<void(const std::string& id)>;

  explicit VirtualClipboard(Requested requested);
  ~VirtualClipboard();

  // Name of the private format that marks Hopboard's virtual data object.
  static UINT MarkerFormat();

  void Write(std::shared_ptr<VirtualItemState> item, int64_t expected_revision,
             WriteDone done);
  // Updates download state; returns false for an unknown item.
  bool Progress(const std::string& id, size_t entry, const std::wstring* path,
                uint64_t available, bool done, bool failed);
  // Empties the clipboard if it still holds this item. Fails pending reads.
  void Clear(const std::string& id, std::function<void(bool)> done);
  // Whether the item with this id is the data object Hopboard last set.
  bool IsCurrent(const std::string& id);

 private:
  void Run();
  void Post(std::function<void()> task);
  std::shared_ptr<VirtualItemState> Find(const std::string& id);

  Requested requested_;
  std::thread thread_;
  std::atomic<DWORD> thread_id_{0};
  HANDLE ready_ = nullptr;
  std::mutex mutex_;
  std::deque<std::function<void()>> tasks_;
  std::shared_ptr<VirtualItemState> current_;
  std::vector<std::weak_ptr<VirtualItemState>> recent_;
  IDataObject* object_ = nullptr;  // OLE thread only
};

#endif
