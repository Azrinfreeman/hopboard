#ifndef LOCALCLIPBOARD_BRIDGE_H_
#define LOCALCLIPBOARD_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <shellapi.h>
#include <memory>
#include <optional>

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
  void Show();
  void Action(const char* action);
};
#endif
