cmake_minimum_required(VERSION 3.25)

set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0" CACHE STRING "Oldest supported macOS release")
set(CMAKE_OSX_ARCHITECTURES "x86_64;arm64" CACHE STRING "Supported macOS architectures")

project(XMeetingModernization VERSION 0.1 LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED YES)
set(CMAKE_CXX_EXTENSIONS NO)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED YES)
set(CMAKE_OBJCXX_EXTENSIONS NO)

add_compile_definitions(XMEETING_H323_ONLY=1)

set(
  XMEETING_H323PLUS_ROOT
  "${CMAKE_CURRENT_LIST_DIR}/../.build/h323plus/macos-universal"
  CACHE PATH
  "Path to the SDK produced by Scripts/build-h323plus-universal.sh"
)

find_path(
  PTLIB_INCLUDE_DIR
  ptlib.h
  PATHS "${XMEETING_H323PLUS_ROOT}/include"
  NO_DEFAULT_PATH
  REQUIRED
)
find_path(
  H323PLUS_INCLUDE_DIR
  h323ep.h
  PATHS "${XMEETING_H323PLUS_ROOT}/include/openh323"
  NO_DEFAULT_PATH
  REQUIRED
)
find_library(
  PTLIB_LIBRARY
  NAMES ptlib
  PATHS "${XMEETING_H323PLUS_ROOT}/lib"
  NO_DEFAULT_PATH
  REQUIRED
)
find_library(
  H323PLUS_LIBRARY
  NAMES h323plus
  PATHS "${XMEETING_H323PLUS_ROOT}/lib"
  NO_DEFAULT_PATH
  REQUIRED
)

find_library(AUDIO_TOOLBOX_FRAMEWORK AudioToolbox REQUIRED)
find_library(AUDIO_UNIT_FRAMEWORK AudioUnit REQUIRED)
find_library(CORE_AUDIO_FRAMEWORK CoreAudio REQUIRED)
find_library(CORE_SERVICES_FRAMEWORK CoreServices REQUIRED)
find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)
find_library(APPKIT_FRAMEWORK AppKit REQUIRED)

add_library(XMH323PlusEngine STATIC H323Plus/XMH323PlusEngine.cpp)
target_include_directories(
  XMH323PlusEngine
  PUBLIC "${CMAKE_CURRENT_LIST_DIR}/H323Plus"
  PRIVATE "${PTLIB_INCLUDE_DIR}" "${H323PLUS_INCLUDE_DIR}"
)
target_compile_definitions(XMH323PlusEngine PRIVATE H323_STATIC_LIB)
target_compile_options(
  XMH323PlusEngine
  PRIVATE
    -Wno-deprecated-declarations
    -Wno-inconsistent-missing-override
    -Wno-unknown-pragmas
)
target_link_libraries(
  XMH323PlusEngine
  PUBLIC
    "${H323PLUS_LIBRARY}"
    "${PTLIB_LIBRARY}"
    "${AUDIO_TOOLBOX_FRAMEWORK}"
    "${AUDIO_UNIT_FRAMEWORK}"
    "${CORE_AUDIO_FRAMEWORK}"
    "${CORE_SERVICES_FRAMEWORK}"
    resolv
)

add_library(XMH323CocoaBridge STATIC Cocoa/XMH323Client.mm)
target_include_directories(
  XMH323CocoaBridge
  PUBLIC "${CMAKE_CURRENT_LIST_DIR}/Cocoa"
  PRIVATE "${PTLIB_INCLUDE_DIR}"
)
target_compile_options(
  XMH323CocoaBridge
  PRIVATE
    -fobjc-arc
    -Wno-deprecated-declarations
    -Wno-inconsistent-missing-override
    -Wno-macro-redefined
    -Wno-unknown-pragmas
)
target_link_libraries(
  XMH323CocoaBridge
  PUBLIC XMH323PlusEngine "${FOUNDATION_FRAMEWORK}"
)

add_executable(h323plus-smoke H323PlusSmoke/main.cpp)
target_include_directories(h323plus-smoke PRIVATE "${PTLIB_INCLUDE_DIR}")
target_compile_options(h323plus-smoke PRIVATE -Wno-inconsistent-missing-override)
target_link_libraries(
  h323plus-smoke
  PRIVATE XMH323PlusEngine
)

add_executable(h323plus-cocoa-smoke CocoaSmoke/main.mm)
target_compile_options(h323plus-cocoa-smoke PRIVATE -fobjc-arc)
target_link_libraries(h323plus-cocoa-smoke PRIVATE XMH323CocoaBridge)

set(
  XMEETING_APP_RESOURCES
  "${CMAKE_CURRENT_LIST_DIR}/../Resources/XMeeting.icns"
  "${CMAKE_CURRENT_LIST_DIR}/../Resources/Images/Call_24.png"
  "${CMAKE_CURRENT_LIST_DIR}/../Resources/Images/hangup_24.png"
  "${CMAKE_CURRENT_LIST_DIR}/../Resources/Images/no_video_screen.png"
  "${CMAKE_CURRENT_LIST_DIR}/../Resources/Images/status_green.png"
  "${CMAKE_CURRENT_LIST_DIR}/../Resources/Images/status_red.png"
  "${CMAKE_CURRENT_LIST_DIR}/../Resources/Images/status_yellow.png"
)
set_source_files_properties(
  ${XMEETING_APP_RESOURCES}
  PROPERTIES MACOSX_PACKAGE_LOCATION "Resources"
)

add_executable(
  XMeeting
  MACOSX_BUNDLE
  App/main.mm
  App/XMAppDelegate.h
  App/XMAppDelegate.mm
  ${XMEETING_APP_RESOURCES}
)
target_include_directories(XMeeting PRIVATE "${CMAKE_CURRENT_LIST_DIR}/App")
target_compile_options(XMeeting PRIVATE -fobjc-arc)
target_link_libraries(XMeeting PRIVATE XMH323CocoaBridge "${APPKIT_FRAMEWORK}")
set_target_properties(
  XMeeting
  PROPERTIES
    MACOSX_BUNDLE TRUE
    MACOSX_BUNDLE_BUNDLE_NAME "XMeeting"
    MACOSX_BUNDLE_BUNDLE_VERSION "0.5.0.1"
    MACOSX_BUNDLE_GUI_IDENTIFIER "net.sourceforge.xmeeting.XMeeting"
    MACOSX_BUNDLE_ICON_FILE "XMeeting.icns"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_LIST_DIR}/App/Info.plist.in"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "0.5.0-alpha"
    OUTPUT_NAME "XMeeting"
)
