cmake_minimum_required(VERSION 3.22)
project(youssira_ct2 CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# --- CTranslate2 précompilé pour Android (voir engine/README.md) -----------
# Adapter le chemin vers l'installation produite par le build CTranslate2
# (libctranslate2.so + include/).
#
# set(CT2_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/ctranslate2-android)
# add_library(ctranslate2 SHARED IMPORTED)
# set_target_properties(ctranslate2 PROPERTIES
#   IMPORTED_LOCATION ${CT2_ROOT}/lib/${ANDROID_ABI}/libctranslate2.so)
# include_directories(${CT2_ROOT}/include)
# ---------------------------------------------------------------------------

add_library(youssira_ct2 SHARED
  jni/ct2_bridge.cpp
)

find_library(log-lib log)

target_link_libraries(youssira_ct2
  # ctranslate2   # décommenter une fois CTranslate2 disponible
  ${log-lib}
)
