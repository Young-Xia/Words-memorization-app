#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"
#include "single_instance.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Check before starting Flutter or opening the user's database.
  SingleInstance single_instance(
      L"Local\\WordsMemory.SingleInstance.09a159fe-7a6d-4bef-aebf-329f17da249d");
  if (!single_instance.valid()) {
    ::MessageBoxW(nullptr,
        L"\u65e0\u6cd5\u68c0\u67e5\u7a0b\u5e8f\u8fd0\u884c\u72b6\u6001\uff0c\u8bf7\u7a0d\u540e\u91cd\u8bd5\u3002",
        L"\u8bcd\u95f4 \u00b7 WordsMemory", MB_OK | MB_ICONERROR | MB_SETFOREGROUND);
    return EXIT_FAILURE;
  }
  if (single_instance.already_running()) {
    ::MessageBoxW(nullptr,
        L"\u8bcd\u95f4\u5df2\u7ecf\u6709\u4e00\u4e2a\u7a0b\u5e8f\u5728\u8fd0\u884c\u3002\n\n\u8bf7\u4f7f\u7528\u5df2\u6253\u5f00\u7684\u7a97\u53e3\uff0c\u6216\u4ece\u7cfb\u7edf\u6258\u76d8\u6253\u5f00\u8bcd\u95f4\u3002",
        L"\u8bcd\u95f4 \u00b7 WordsMemory", MB_OK | MB_ICONINFORMATION | MB_SETFOREGROUND);
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"WordsMemory", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
