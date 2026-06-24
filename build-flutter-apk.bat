@echo off
set ROOT=%~dp0
set API_BASE_URL=%~1
if "%API_BASE_URL%"=="" (
  echo Uso: build-flutter-apk.bat https://TU-URL-PUBLICA
  echo Ejemplo: build-flutter-apk.bat https://induccion-gerencia-comercial.onrender.com
  exit /b 1
)
set JAVA_HOME=%ROOT%.tools\jdk\jdk-21.0.11+10
set ANDROID_SDK_ROOT=%ROOT%.tools\android-sdk
set ANDROID_HOME=%ROOT%.tools\android-sdk
set PUB_CACHE=%ROOT%.tools\pub-cache
set PATH=%JAVA_HOME%\bin;%ANDROID_SDK_ROOT%\cmdline-tools\latest\bin;%ANDROID_SDK_ROOT%\platform-tools;%ROOT%.tools\flutter\bin\mingit\cmd;%ROOT%.tools\flutter\bin;%PATH%
cd /d "%ROOT%mobile-app"
"%ROOT%.tools\flutter\bin\flutter.bat" build apk --debug --dart-define=API_BASE_URL=%API_BASE_URL%
