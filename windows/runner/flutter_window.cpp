#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <mmsystem.h>

#include <optional>

#pragma comment(lib, "winmm.lib")

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Dart hands over the sounds once ("load", name to bytes), then asks for
  // one by name ("play"). A new sound replaces one still playing.
  sound_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "exam_corrector/sound",
      &flutter::StandardMethodCodec::GetInstance());
  sound_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "load") {
          if (const auto* map = std::get_if<flutter::EncodableMap>(call.arguments())) {
            PlaySound(nullptr, nullptr, 0);  // Nothing may still read the old bytes.
            sounds_.clear();
            for (const auto& [key, value] : *map) {
              const auto* name = std::get_if<std::string>(&key);
              const auto* bytes = std::get_if<std::vector<uint8_t>>(&value);
              if (name && bytes) sounds_[*name] = *bytes;
            }
          }
          result->Success();
        } else if (call.method_name() == "play") {
          if (const auto* name = std::get_if<std::string>(call.arguments())) {
            auto found = sounds_.find(*name);
            if (found != sounds_.end() && !found->second.empty()) {
              PlaySound(reinterpret_cast<LPCWSTR>(found->second.data()), nullptr,
                        SND_MEMORY | SND_ASYNC | SND_NODEFAULT);
            }
          }
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  PlaySound(nullptr, nullptr, 0);
  sound_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
