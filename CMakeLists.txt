cmake_minimum_required(VERSION 3.25)
project(AnonCamWrapper
    VERSION 1.0.0
    LANGUAGES C CXX OBJCXX
)

# C++ and Objective-C++ standards
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_OBJCXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# macOS specific
set(CMAKE_OSX_DEPLOYMENT_TARGET "15.0")
set(CMAKE_MACOS_RPATH ON)
set(CMAKE_INSTALL_RPATH_USE_LINK_PATH TRUE)

# Find frameworks
find_library(COREVIDEO_FRAMEWORK CoreVideo REQUIRED)
find_library(COREMEDIA_FRAMEWORK CoreMedia REQUIRED)
find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)
find_library(METAL_FRAMEWORK Metal REQUIRED)
find_library(QUARTZCORE_FRAMEWORK QuartzCore REQUIRED)

# MediaPipe configuration
# Set MediaPath path or use system-installed
set(MEDIAPIPE_ROOT "" CACHE PATH "Path to MediaPipe installation")

if(MEDIAPIPE_ROOT)
    set(MEDIAPIPE_INCLUDE_DIR "${MEDIAPIPE_ROOT}/include")
    set(MEDIAPIPE_LIB_DIR "${MEDIAPIPE_ROOT}/lib")
else()
    message(STATUS "MEDIAPIPE_ROOT not set - using stub implementation")
    set(MEDIAPIPE_INCLUDE_DIR "")
    set(MEDIAPIPE_LIB_DIR "")
endif()

# Create static library
add_library(AnonCamWrapper STATIC
    MediapipeWrapper/src/FaceTracker.cpp
    MediapipeWrapper/src/FaceTrackerBridge.mm
)

target_include_directories(AnonCamWrapper
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/MediapipeWrapper/include>
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/Shared/Headers>
        ${MEDIAPIPE_INCLUDE_DIR}
)

target_link_libraries(AnonCamWrapper
    PUBLIC
        ${COREVIDEO_FRAMEWORK}
        ${COREMEDIA_FRAMEWORK}
        ${FOUNDATION_FRAMEWORK}
)

# Enable Objective-C++ ARC for .mm files
set_target_properties(AnonCamWrapper PROPERTIES
    OSX_ARCHITECTURES "x86_64;arm64"
    FRAMEWORK TRUE
    MACOSX_BUNDLE TRUE
)

# Optional: Tests
option(BUILD_TESTS "Build tests" OFF)

if(BUILD_TESTS)
    enable_testing()
    add_subdirectory(Tests)
endif()

# Install
install(TARGETS AnonCamWrapper
    FRAMEWORK DESTINATION Library/Frameworks
    LIBRARY DESTINATION lib
    ARCHIVE DESTINATION lib
)

install(FILES
    MediapipeWrapper/include/FaceTracker.h
    Shared/Headers/FaceTrackerBridge.h
    DESTINATION include/AnonCam
)

# CPack configuration for creating packages
include(CPack)
