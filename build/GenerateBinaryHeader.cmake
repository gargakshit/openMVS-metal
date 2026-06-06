# Copyright (c) 2026-present Akshit Garg <git+openmvs-metal@akshit.network>
# Codex sign-off: OpenAI Codex assisted with this file.

if(NOT DEFINED INPUT OR INPUT STREQUAL "")
	message(FATAL_ERROR "INPUT is required")
endif()
if(NOT DEFINED OUTPUT OR OUTPUT STREQUAL "")
	message(FATAL_ERROR "OUTPUT is required")
endif()
if(NOT DEFINED SYMBOL_PREFIX OR SYMBOL_PREFIX STREQUAL "")
	message(FATAL_ERROR "SYMBOL_PREFIX is required")
endif()

file(READ "${INPUT}" BINARY_HEX HEX)
string(LENGTH "${BINARY_HEX}" BINARY_HEX_LENGTH)
math(EXPR BINARY_SIZE "${BINARY_HEX_LENGTH} / 2")
string(REGEX REPLACE "([0-9A-Fa-f][0-9A-Fa-f])" "0x\\1," BINARY_ARRAY "${BINARY_HEX}")
string(REGEX REPLACE "((0x[0-9A-Fa-f][0-9A-Fa-f],){16})" "\\1\n" BINARY_ARRAY "${BINARY_ARRAY}")

file(WRITE "${OUTPUT}"
	"/* Generated from ${INPUT} by CMake; do not edit. */\n"
	"#pragma once\n"
	"static constexpr const unsigned char ${SYMBOL_PREFIX}Data[] = {\n"
	"${BINARY_ARRAY}\n"
	"};\n"
	"static constexpr const unsigned int ${SYMBOL_PREFIX}Size = ${BINARY_SIZE}u;\n")
