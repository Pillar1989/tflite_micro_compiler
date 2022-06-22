SET(LIB_NAME tensorflow-microlite)

IF(TF_RECACHE)
    MESSAGE(STATUS "Rebasing TensorFlow source")
    UNSET(TF_TAG CACHE)
    UNSET(TF_COMMIT CACHE)
ENDIF()

IF(NOT TF_SRC)
    INCLUDE(FetchContent)
    IF(TF_TAG)
        MESSAGE(STATUS "Getting TF tag '${TF_TAG}' and not master")
        FetchContent_Declare(
            tf 
            GIT_REPOSITORY https://github.com/tensorflow/tensorflow.git
            GIT_PROGRESS FALSE
            GIT_REMOTE_UPDATE_STRATEGY REBASE_CHECKOUT
            GIT_TAG ${TF_TAG}
            QUIET
            )
    ELSEIF(TF_COMMIT)
        MESSAGE(STATUS "Getting TF commit '${TF_COMMIT}' and not master")
        FetchContent_Declare(
            tf
            GIT_REPOSITORY https://github.com/tensorflow/tensorflow.git
            GIT_PROGRESS FALSE
            GIT_REMOTE_UPDATE_STRATEGY REBASE_CHECKOUT
            GIT_TAG ${TF_COMMIT}
            QUIET
            )
    ELSE()
        FetchContent_Declare(
            tf 
            GIT_REPOSITORY https://github.com/tensorflow/tensorflow.git
            GIT_PROGRESS FALSE
            GIT_REMOTE_UPDATE_STRATEGY REBASE_CHECKOUT
            QUIET
            )
    ENDIF()
    FetchContent_GetProperties(tf)
    IF(NOT tf_POPULATED)
        MESSAGE(STATUS "TensorFlow sources not given/populated, fetching from GH...")
        FetchContent_Populate(tf)
    ENDIF()
    SET(TF_SRC ${tf_SOURCE_DIR})

    FetchContent_Declare(
        flatbuffers 
        GIT_REPOSITORY https://github.com/google/flatbuffers.git 
        GIT_PROGRESS FALSE 
        QUIET
        )
    FetchContent_GetProperties(flatbuffers)
    IF(NOT flatbuffers_POPULATED)
        MESSAGE(STATUS "Now getting 'flatbuffers'...")
        FetchContent_Populate(flatbuffers)
    ENDIF()
    LIST(APPEND TFL_INC_DIRS ${flatbuffers_SOURCE_DIR}/include)

    FetchContent_Declare(
        fixedpoint 
        GIT_REPOSITORY https://github.com/google/gemmlowp.git 
        GIT_PROGRESS FALSE 
        QUIET 
        )
    FetchContent_GetProperties(fixedpoint)
    IF(NOT fixedpoint_POPULATED)
        MESSAGE(STATUS "And finaly 'fixedpoint'...")
        FetchContent_Populate(fixedpoint)
    ENDIF()
    LIST(APPEND TFL_INC_DIRS ${fixedpoint_SOURCE_DIR})

    FetchContent_Declare(
        ruy 
        GIT_REPOSITORY https://github.com/google/ruy.git 
        GIT_PROGRESS FALSE 
        QUIET 
        )
    FetchContent_GetProperties(ruy)
    IF(NOT ruy_POPULATED)
        MESSAGE(STATUS "Oh we also need 'ruy'...")
        FetchContent_Populate(ruy)
    ENDIF()
    LIST(APPEND TFL_INC_DIRS ${ruy_SOURCE_DIR})
ENDIF()

SET(TFL_SRC ${TF_SRC}/tensorflow/lite)
SET(TFLM_SRC ${TFL_SRC}/micro)
SET(TFLD_SRC ${TFL_SRC}/tools/make/downloads)
SET(TFLMD_SRC ${TFLM_SRC}/tools/make/downloads)

IF(EXISTS ${TFLD_SRC}/flatbuffers/include)
    LIST(APPEND TFL_INC_DIRS ${TFLD_SRC}/flatbuffers/include)
ELSEIF(EXISTS ${TFLMD_SRC}/flatbuffers/include)
    LIST(APPEND TFL_INC_DIRS ${TFLMD_SRC}/flatbuffers/include)
ENDIF()

IF(EXISTS ${TFLD_SRC}/gemmlowp)
    LIST(APPEND TFL_INC_DIRS ${TFLD_SRC}/gemmlowp)
ELSEIF(EXISTS ${TFLMD_SRC}/gemmlowp)
    LIST(APPEND TFL_INC_DIRS ${TFLMD_SRC}/gemmlowp)
ENDIF()

IF(EXISTS ${TFLD_SRC}/ruy)
    LIST(APPEND TFL_INC_DIRS ${TFLD_SRC}/ruy)
ELSEIF(EXISTS ${TFLMD_SRC}/ruy)
    LIST(APPEND TFL_INC_DIRS ${TFLMD_SRC}/ruy)
ENDIF()

# SET(CUSTOM_QUANT_SRC ${TFL_SRC}/experimental/custom_quantization_util.cc)
# IF(EXISTS ${CUSTOM_QUANT_SRC})
#     SET(TFL_OPT_SRCS ${CUSTOM_QUANT_SRC})
# ENDIF()

LIST(APPEND TFL_INC_DIRS 
    ${TF_SRC}
    )

FILE(GLOB TFL_ROOT_SRCS
    ${TFLM_SRC}/*.cc 
    )
# schema_utils.cc only exists for newer TF versions
IF(EXISTS ${TFL_SRC}/schema/schema_utils.cc)
    LIST(APPEND TFL_ROOT_SRCS ${TFL_SRC}/schema/schema_utils.cc)
ENDIF()

FILE(GLOB TFL_KERNELS_SRCS
    ${TFLM_SRC}/kernels/*.cc 
    ${TFL_SRC}/kernels/internal/quantization_util.cc 
    ${TFL_SRC}/kernels/kernel_util.cc
    ${TFLM_SRC}/kernels/kernel_util.cc
    )

# These ones carry an unwanted dependecy (TODO: Fix)
FILE(GLOB TFL_KERNELS_TO_REMOVE
    # ${TFLM_SRC}/kernels/depth_to_space.cc
    # ${TFLM_SRC}/kernels/space_to_depth.cc
    # ${TFLM_SRC}/kernels/gather.cc
    # ${TFLM_SRC}/kernels/transpose.cc
    # ${TFLM_SRC}/kernels/floor_mod.cc
    # ${TFLM_SRC}/kernels/floor_div.cc
    )
FOREACH(src ${TFL_KERNELS_TO_REMOVE})
    LIST(FIND TFL_KERNELS_SRCS ${src} TFL_KERNELS_SRCS_FOUND_INDEX)
    IF(${TFL_KERNELS_SRCS_FOUND_INDEX} GREATER_EQUAL 0)
        LIST(REMOVE_ITEM TFL_KERNELS_SRCS ${src})
    ENDIF()
ENDFOREACH()

IF(TFLM_EXTRA_KERNELS)
    FILE(GLOB TFL_EXTRA_KERNEL_SRCS
	    ${TFLM_SRC}/kernels/${TFLM_EXTRA_KERNELS}/*.cc
        )
    FOREACH(src ${TFL_EXTRA_KERNEL_SRCS})
        GET_FILENAME_COMPONENT(src_name ${src} NAME)
        SET(src_path "${TFLM_SRC}/kernels/${src_name}")
        LIST(FIND TFL_KERNELS_SRCS ${src_path} TFL_KERNELS_SRCS_FOUND_INDEX)
        IF(${TFL_KERNELS_SRCS_FOUND_INDEX} GREATER_EQUAL 0)
            MESSAGE(STATUS "Replacing TFLM version of ${src_name} by ${TFLM_EXTRA_KERNELS} variant...")
            LIST(REMOVE_ITEM TFL_KERNELS_SRCS ${src_path})
        ENDIF()
    ENDFOREACH()
ENDIF()

FILE(GLOB TFL_CORE_API_SRCS
    ${TFL_SRC}/core/api/*.cc 
    )

FILE(GLOB TFL_C_SRCS
    ${TFL_SRC}/c/common.cc
    )

FILE(GLOB TFL_MEM_PLANNER_SRCS
    ${TFLM_SRC}/memory_planner/*.cc
    )

FILE(GLOB TFL_ARENA_ALLOCATOR_SRCS
    ${TFLM_SRC}/arena_allocator/*.cc
    )

SET(TFL_SRCS 
    ${TFL_ROOT_SRCS}
    ${TFL_KERNELS_SRCS}
    ${TFL_EXTRA_KERNEL_SRCS}
    ${TFL_CORE_API_SRCS}
    ${TFL_C_SRCS}
    ${TFL_MEM_PLANNER_SRCS}
    ${TFL_ARENA_ALLOCATOR_SRCS}
    ${TFL_OPT_SRCS}
    )

MESSAGE(STATUS "TFL_SRCS=${TFL_SRCS}")

LIST(FILTER TFL_SRCS EXCLUDE REGEX "([a-z0-9_]+_test.cc)$")

IF(RECORD_STATIC_KERNELS)
    LIST(APPEND TFL_INC_DIRS ${TFLITE_STATIC_INIT_PATH})
    LIST(APPEND TFL_SRCS
	 ${TFLITE_STATIC_INIT_PATH}/static_data_utils.cc
	 ${TFLITE_STATIC_INIT_PATH}/static_init_support.cc
    )
ENDIF()

ADD_LIBRARY(${LIB_NAME} STATIC
    ${TFL_SRCS}
)

TARGET_INCLUDE_DIRECTORIES(${LIB_NAME} PUBLIC
    ${TFL_INC_DIRS}
    /home/philipp/src/tflmc/CMSIS_5/
    /home/philipp/src/tflmc/CMSIS_5/CMSIS/Core/Include/
    /home/philipp/src/tflmc/CMSIS_5/CMSIS/NN/Include/
    /home/philipp/src/tflmc/CMSIS_5/CMSIS/DSP/Include/
)

TARGET_LINK_LIBRARIES(${LIB_NAME} PUBLIC /home/philipp/src/tflmc/CMSIS_5/CMSIS/NN/build/Source/libcmsis-nn.a)

TARGET_COMPILE_DEFINITIONS(${LIB_NAME} PUBLIC
    TF_LITE_USE_GLOBAL_MAX
    TF_LITE_USE_GLOBAL_MIN
    TF_LITE_USE_GLOBAL_CMATH_FUNCTIONS
    TF_LITE_STATIC_MEMORY
    TFLITE_EMULATE_FLOAT
    CMSIS_NN
    "$<$<CONFIG:RELEASE>:TF_LITE_STRIP_ERROR_STRINGS>"
)

TARGET_COMPILE_DEFINITIONS(${LIB_NAME} PUBLIC
    PREINTERPRETER
)

IF(RECORD_STATIC_KERNELS)
    TARGET_COMPILE_DEFINITIONS(${LIB_NAME} PUBLIC
        TF_LITE_MICRO_RECORD_STATIC_KERNEL_VARIANT
        TF_LITE_MICRO_AUTO_DUMP_POINTER_TABLES
        STATIC_INIT_OUT_FILE="${TF_SRC}/tensorflow/lite/micro/kernels/recorded_model/static_eval_tables.cc"
    )
ENDIF()

SET(TFLite_INCLUDE_DIRS 
    ${TFL_INC_DIRS}
    )

SET(TFLite_SOURCES 
    ${TFL_SRCS}
    )

INCLUDE(FindPackageHandleStandardArgs)

FIND_PACKAGE_HANDLE_STANDARD_ARGS(TFLite DEFAULT_MSG TFLite_INCLUDE_DIRS TFLite_SOURCES)
