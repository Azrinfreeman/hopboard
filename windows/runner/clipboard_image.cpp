#include "clipboard_image.h"
#include <wincodec.h>
#include <wrl/client.h>
#include <algorithm>
#include <cstring>
#include <stdexcept>

using Microsoft::WRL::ComPtr;
namespace {
constexpr size_t kMaxPng = 16 * 1024 * 1024;
void Check(HRESULT hr) {
  if (FAILED(hr)) throw std::runtime_error("Image conversion failed.");
}
void Dimensions(UINT width, UINT height) {
  if (!width || !height || width > 16384 || height > 16384 ||
      static_cast<uint64_t>(width) * height > 50000000) {
    throw std::runtime_error("Images must be at most 50 megapixels and 16384 pixels per side.");
  }
}
ComPtr<IWICImagingFactory> Factory() {
  ComPtr<IWICImagingFactory> factory;
  Check(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                        IID_PPV_ARGS(&factory)));
  return factory;
}
ComPtr<IWICBitmapFrameDecode> Decode(IWICImagingFactory* factory,
                                   const std::vector<uint8_t>& png) {
  const uint8_t signature[] = {137, 80, 78, 71, 13, 10, 26, 10};
  if (png.size() < 33 || png.size() > kMaxPng ||
      std::memcmp(png.data(), signature, sizeof(signature)) != 0) {
    throw std::runtime_error("Use a PNG image up to 16 MiB.");
  }
  ComPtr<IWICStream> stream;
  Check(factory->CreateStream(&stream));
  Check(stream->InitializeFromMemory(const_cast<BYTE*>(png.data()), static_cast<DWORD>(png.size())));
  ComPtr<IWICBitmapDecoder> decoder;
  Check(factory->CreateDecoderFromStream(stream.Get(), nullptr, WICDecodeMetadataCacheOnDemand, &decoder));
  ComPtr<IWICBitmapFrameDecode> frame;
  Check(decoder->GetFrame(0, &frame));
  UINT width, height;
  Check(frame->GetSize(&width, &height));
  Dimensions(width, height);
  return frame;
}
HGLOBAL Memory(const void* data, size_t size) {
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, size);
  if (!memory) throw std::runtime_error("Image allocation failed.");
  void* target = GlobalLock(memory);
  if (!target) { GlobalFree(memory); throw std::runtime_error("Image allocation failed."); }
  std::memcpy(target, data, size);
  GlobalUnlock(memory);
  return memory;
}
}

PreparedClipboardImage::~PreparedClipboardImage() {
  if (png) GlobalFree(png);
  if (dib) GlobalFree(dib);
}

ClipboardImage ConvertClipboardImage(UINT format, const std::vector<uint8_t>& bytes) {
  auto factory = Factory();
  ClipboardImage result;
  if (format == RegisterClipboardFormatW(L"PNG")) {
    auto frame = Decode(factory.Get(), bytes);
    Check(frame->GetSize(&result.width, &result.height));
    result.png = bytes;
    return result;
  }
  if (bytes.size() < sizeof(BITMAPINFOHEADER)) throw std::runtime_error("Invalid clipboard bitmap.");
  BITMAPINFOHEADER header;
  std::memcpy(&header, bytes.data(), sizeof(header));
  if (header.biSize < sizeof(header) || header.biSize > sizeof(BITMAPV5HEADER) ||
      header.biSize > bytes.size() || header.biWidth <= 0 || header.biHeight == LONG_MIN ||
      header.biPlanes != 1 || (header.biCompression != BI_RGB && header.biCompression != BI_BITFIELDS) ||
      (header.biBitCount != 1 && header.biBitCount != 4 && header.biBitCount != 8 &&
       header.biBitCount != 16 && header.biBitCount != 24 && header.biBitCount != 32)) {
    throw std::runtime_error("Unsupported clipboard bitmap.");
  }
  result.width = static_cast<UINT>(header.biWidth);
  result.height = static_cast<UINT>(header.biHeight < 0 ? -header.biHeight : header.biHeight);
  Dimensions(result.width, result.height);
  const uint64_t stride = ((static_cast<uint64_t>(result.width) * header.biBitCount + 31) / 32) * 4;
  const uint64_t colors = header.biClrUsed ? header.biClrUsed :
    header.biBitCount <= 8 ? (1ULL << header.biBitCount) : 0;
  const uint64_t offset = header.biSize + colors * sizeof(RGBQUAD) +
    (header.biSize == sizeof(header) && header.biCompression == BI_BITFIELDS ? 12 : 0);
  if (offset + stride * result.height > bytes.size()) throw std::runtime_error("Truncated clipboard bitmap.");
  HDC dc = GetDC(nullptr);
  HBITMAP bitmap = CreateDIBitmap(dc, &header, CBM_INIT, bytes.data() + offset,
    reinterpret_cast<const BITMAPINFO*>(bytes.data()), DIB_RGB_COLORS);
  ReleaseDC(nullptr, dc);
  if (!bitmap) throw std::runtime_error("Could not read clipboard bitmap.");
  ComPtr<IWICBitmap> source;
  const auto created = factory->CreateBitmapFromHBITMAP(bitmap, nullptr, WICBitmapIgnoreAlpha, &source);
  DeleteObject(bitmap);
  Check(created);
  ComPtr<IStream> stream;
  Check(CreateStreamOnHGlobal(nullptr, TRUE, &stream));
  ComPtr<IWICBitmapEncoder> encoder;
  Check(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder));
  Check(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache));
  ComPtr<IWICBitmapFrameEncode> frame;
  Check(encoder->CreateNewFrame(&frame, nullptr));
  Check(frame->Initialize(nullptr));
  Check(frame->SetSize(result.width, result.height));
  WICPixelFormatGUID pixel = GUID_WICPixelFormat24bppBGR;
  Check(frame->SetPixelFormat(&pixel));
  Check(frame->WriteSource(source.Get(), nullptr));
  Check(frame->Commit());
  Check(encoder->Commit());
  STATSTG stat{};
  Check(stream->Stat(&stat, STATFLAG_NONAME));
  if (stat.cbSize.QuadPart > kMaxPng) throw std::runtime_error("The PNG image exceeds 16 MiB.");
  HGLOBAL memory;
  Check(GetHGlobalFromStream(stream.Get(), &memory));
  const auto* buffer = static_cast<const uint8_t*>(GlobalLock(memory));
  if (!buffer) throw std::runtime_error("Image allocation failed.");
  result.png.assign(buffer, buffer + static_cast<size_t>(stat.cbSize.QuadPart));
  GlobalUnlock(memory);
  return result;
}

void PrepareClipboardImage(const std::vector<uint8_t>& png, PreparedClipboardImage& output) {
  auto factory = Factory();
  auto frame = Decode(factory.Get(), png);
  UINT width, height;
  Check(frame->GetSize(&width, &height));
  ComPtr<IWICFormatConverter> converter;
  Check(factory->CreateFormatConverter(&converter));
  Check(converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppBGRA,
    WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom));
  const UINT stride = width * 4;
  const UINT size = stride * height;
  std::vector<uint8_t> dib(sizeof(BITMAPV5HEADER) + size, 0);
  auto* header = reinterpret_cast<BITMAPV5HEADER*>(dib.data());
  header->bV5Size = sizeof(BITMAPV5HEADER);
  header->bV5Width = static_cast<LONG>(width);
  header->bV5Height = -static_cast<LONG>(height);
  header->bV5Planes = 1;
  header->bV5BitCount = 32;
  header->bV5Compression = BI_BITFIELDS;
  header->bV5SizeImage = size;
  header->bV5RedMask = 0x00ff0000;
  header->bV5GreenMask = 0x0000ff00;
  header->bV5BlueMask = 0x000000ff;
  header->bV5AlphaMask = 0xff000000;
  header->bV5CSType = LCS_sRGB;
  Check(converter->CopyPixels(nullptr, stride, size, dib.data() + sizeof(BITMAPV5HEADER)));
  output.png = Memory(png.data(), png.size());
  output.dib = Memory(dib.data(), dib.size());
}
