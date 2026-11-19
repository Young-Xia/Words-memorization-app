@echo off
rem Call this from cmd.exe to enable the installed x64 C++ and Flutter tools.
set "WORDSMEMORY_VS="
set "WORDSMEMORY_VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%WORDSMEMORY_VSWHERE%" (
  echo Visual Studio Build Tools not found.
  exit /b 1
)
for /f "usebackq tokens=*" %%i in (`"%WORDSMEMORY_VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 Microsoft.VisualStudio.Component.VC.CMake.Project -property installationPath`) do set "WORDSMEMORY_VS=%%i"
if not defined WORDSMEMORY_VS (
  echo C++ compiler or CMake component missing.
  exit /b 1
)
call "%WORDSMEMORY_VS%\Common7\Tools\VsDevCmd.bat" -host_arch=x64 -arch=x64
if errorlevel 1 exit /b 1
set "PATH=%~dp0..\.tools\flutter\bin;%PATH%"
set "PUB_CACHE=%~dp0..\.tools\pub-cache"
echo C++ x64 and Flutter environment ready for this terminal.
