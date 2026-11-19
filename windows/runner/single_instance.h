#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <windows.h>

// Keeping this handle open reserves the name until the process exits, including
// while its Flutter window is hidden in the tray. Windows cleans up after crashes.
class SingleInstance {
 public:
  explicit SingleInstance(const wchar_t* name) {
    handle_ = ::CreateMutexW(nullptr, FALSE, name);
    error_ = ::GetLastError();
  }
  ~SingleInstance() {
    if (handle_) ::CloseHandle(handle_);
  }
  SingleInstance(const SingleInstance&) = delete;
  SingleInstance& operator=(const SingleInstance&) = delete;

  bool valid() const { return handle_ != nullptr; }
  bool already_running() const { return valid() && error_ == ERROR_ALREADY_EXISTS; }

 private:
  HANDLE handle_ = nullptr;
  DWORD error_ = ERROR_SUCCESS;
};

#endif  // RUNNER_SINGLE_INSTANCE_H_
