#ifndef LOCALCLIPBOARD_BRIDGE_H_
#define LOCALCLIPBOARD_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <shellapi.h>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <thread>
#include <vector>
#include <string>

struct ClipboardImageJob;
class VirtualClipboard;

class ClipboardBridge {
 public:
  ClipboardBridge(HWND window, flutter::BinaryMessenger* messenger);
  ~ClipboardBridge();
  std::optional<LRESULT> Handle(UINT message, WPARAM wparam, LPARAM lparam);
 private:
  HWND window_;
  DWORD own_revision_ = 0;
  bool paused_ = false;
  bool tray_ready_ = false;
  HANDLE network_notification_ = nullptr;
  NOTIFYICONDATAW tray_{};
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::thread image_worker_;
  std::shared_ptr<ClipboardImageJob> image_job_;
  std::vector<uint8_t> image_bytes_, write_image_;
  std::string image_token_, write_token_;
  uint64_t image_serial_ = 0;
  uint64_t image_write_generation_ = 0;
  size_t write_size_ = 0;
  std::unique_ptr<VirtualClipboard> virtual_;
  std::mutex main_mutex_;
  std::deque<std::function<void()>> main_tasks_;
  // Runs a task on the platform thread (from any thread).
  void PostMain(std::function<void()> task);
  void CompleteImage();
  void Show();
  void Action(const char* action);
};
#endif
