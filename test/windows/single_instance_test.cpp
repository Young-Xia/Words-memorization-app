#include <windows.h>

#include <string>
#include <vector>

#include "../../windows/runner/single_instance.h"

int Probe(const std::wstring& name) {
  wchar_t executable[MAX_PATH];
  if (!GetModuleFileNameW(nullptr, executable, MAX_PATH)) return 99;
  const std::wstring command = L"\"" + std::wstring(executable) + L"\" --probe " + name;
  std::vector<wchar_t> args(command.begin(), command.end());
  args.push_back(L'\0');
  STARTUPINFOW startup = {};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process = {};
  if (!CreateProcessW(nullptr, args.data(), nullptr, nullptr, FALSE,
                      CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process)) return 99;
  const DWORD waited = WaitForSingleObject(process.hProcess, 5000);
  DWORD code = 99;
  if (waited == WAIT_OBJECT_0) GetExitCodeProcess(process.hProcess, &code);
  CloseHandle(process.hThread);
  CloseHandle(process.hProcess);
  return static_cast<int>(code);
}

int wmain(int argc, wchar_t** argv) {
  if (argc == 3 && std::wstring(argv[1]) == L"--probe") {
    SingleInstance instance(argv[2]);
    if (!instance.valid()) return 99;
    return instance.already_running() ? 10 : 0;
  }
  const auto name = L"Local\\WordsMemory.Test." + std::to_wstring(GetCurrentProcessId());
  {
    SingleInstance first(name.c_str());
    if (!first.valid() || first.already_running()) return 1;
    // A separate process must see the reservation while the first instance lives.
    if (Probe(name) != 10) return 2;
  }
  // Closing the last handle must permit a fresh launch, without a stale lock.
  if (Probe(name) != 0) return 3;
  return 0;
}
