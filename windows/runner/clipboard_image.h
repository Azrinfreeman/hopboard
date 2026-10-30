#ifndef HOPBOARD_CLIPBOARD_IMAGE_H_
#define HOPBOARD_CLIPBOARD_IMAGE_H_
#include <windows.h>
#include <cstdint>
#include <vector>

struct ClipboardImage {
  std::vector<uint8_t> png;
  UINT width = 0, height = 0;
};

struct PreparedClipboardImage {
  HGLOBAL png = nullptr, dib = nullptr;
  ~PreparedClipboardImage();
};

// Both run on a COM-initialized worker, outside the clipboard lock.
ClipboardImage ConvertClipboardImage(UINT format, const std::vector<uint8_t>& bytes);
void PrepareClipboardImage(const std::vector<uint8_t>& png, PreparedClipboardImage& output);
#endif
