cmake_minimum_required(VERSION 3.22)
project(youssira_native CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_library(log-lib log)

# --- CTranslate2 précompilé pour Android (voir engine/README.md) -----------
# Compile CTranslate2 avec WITH_SENTENCEPIECE=ON, puis pointe CT2_ROOT vers
# l'installation produite (libctranslate2.so + include/).
set(CT2_ROOT "" CACHE PATH "Chemin vers l'installation CTranslate2 Android")
if(NOT CT2_ROOT STREQUAL "")
  add_library(ctranslate2 SHARED IMPORTED)
  set_target_properties(ctranslate2 PROPERTIES
    IMPORTED_LOCATION ${CT2_ROOT}/lib/${ANDROID_ABI}/libctranslate2.so)
  include_directories(${CT2_ROOT}/include)

  add_library(youssira_ct2 SHARED
    jni/ct2_bridge.cpp
  )
  target_link_libraries(youssira_ct2
    ctranslate2
    ${log-lib}
  )
endif()
# ---------------------------------------------------------------------------

# --- llama.cpp précompilé pour Android (chat local, engine/README.md) ------
# Compile llama.cpp pour arm64-v8a, puis pointe LLAMA_ROOT vers
# l'installation produite (libllama.so + include/).
set(LLAMA_ROOT "" CACHE PATH "Chemin vers l'installation llama.cpp Android")
if(NOT LLAMA_ROOT STREQUAL "")
  set(LLAMA_LIBS "")
  foreach(lib llama ggml ggml-base ggml-cpu)
    if(EXISTS ${LLAMA_ROOT}/lib/${ANDROID_ABI}/lib${lib}.so)
      add_library(${lib} SHARED IMPORTED)
      set_target_properties(${lib} PROPERTIES
        IMPORTED_LOCATION ${LLAMA_ROOT}/lib/${ANDROID_ABI}/lib${lib}.so)
      list(APPEND LLAMA_LIBS ${lib})
    endif()
  endforeach()
  include_directories(${LLAMA_ROOT}/include)

  add_library(youssira_llama SHARED
    jni/llama_bridge.cpp
  )
  target_link_libraries(youssira_llama
    ${LLAMA_LIBS}
    ${log-lib}
  )
endif()
# ---------------------------------------------------------------------------
