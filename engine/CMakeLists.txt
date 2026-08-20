cmake_minimum_required(VERSION 3.22)
project(youssira_ct2 CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# --- CTranslate2 précompilé pour Android (voir engine/README.md) -----------
# Compile CTranslate2 avec WITH_SENTENCEPIECE=ON, puis pointe CT2_ROOT vers
# l'installation produite (libctranslate2.so + include/).
set(CT2_ROOT "" CACHE PATH "Chemin vers l'installation CTranslate2 Android")
if(NOT CT2_ROOT STREQUAL "")
  add_library(ctranslate2 SHARED IMPORTED)
  set_target_properties(ctranslate2 PROPERTIES
    IMPORTED_LOCATION ${CT2_ROOT}/lib/${ANDROID_ABI}/libctranslate2.so)
  include_directories(${CT2_ROOT}/include)
endif()
# ---------------------------------------------------------------------------

add_library(youssira_ct2 SHARED
  jni/ct2_bridge.cpp
)

find_library(log-lib log)

target_link_libraries(youssira_ct2
  # ctranslate2   # décommenter une fois CT2_ROOT défini
  ${log-lib}
)
