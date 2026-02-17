PRIV_DIR = priv
NIF_SO = $(PRIV_DIR)/ex_openzl_nif.so

# Erlang NIF headers
ERTS_INCLUDE_DIR ?= $(shell erl -noshell -eval "io:format(\"~s/erts-~s/include\", [code:root_dir(), erlang:system_info(version)])." -s init stop)
ERL_INTERFACE_INCLUDE_DIR ?= $(shell erl -noshell -eval "io:format(\"~s\", [code:lib_dir(erl_interface, include)])." -s init stop)

# Fine headers
FINE_INCLUDE_DIR ?= $(shell elixir -e "IO.write(Fine.include_dir())")

# OpenZL paths
OPENZL_DIR = c_src/openzl
OPENZL_BUILD_DIR = $(OPENZL_DIR)/build
OPENZL_LIB = $(OPENZL_BUILD_DIR)/libopenzl.a
OPENZL_ZSTD_LIB = $(OPENZL_BUILD_DIR)/zstd_build/lib/libzstd.a
OPENZL_LZ4_LIB = $(OPENZL_BUILD_DIR)/lz4_build/liblz4.a
OPENZL_INCLUDE_DIR = $(OPENZL_DIR)/include

# Compiler settings
CXX ?= c++
CXXFLAGS = -std=c++17 -O2 -fPIC -fvisibility=hidden -Wall -Wextra -Wno-unused-parameter
CXXFLAGS += -I$(ERTS_INCLUDE_DIR)
CXXFLAGS += -I$(FINE_INCLUDE_DIR)
CXXFLAGS += -I$(OPENZL_INCLUDE_DIR)
# Project-root include for SDDL compiler headers (e.g. "tools/sddl/compiler/...")
CXXFLAGS += -I$(OPENZL_DIR)
# C++ poly headers (e.g. "openzl/cpp/poly/StringView.hpp")
CXXFLAGS += -I$(OPENZL_DIR)/cpp/include
# Generated config header
CXXFLAGS += -I$(OPENZL_BUILD_DIR)/include
# Private OpenZL sources (needed by SDDL compiler for shared headers like a1cbor.h)
CXXFLAGS += -I$(OPENZL_DIR)/src

# Platform-specific linker flags
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
	LDFLAGS = -dynamiclib -undefined dynamic_lookup
else
	LDFLAGS = -shared
endif

# Sources - NIF
NIF_SRC = c_src/ex_openzl_nif.cpp
NIF_OBJ = c_src/ex_openzl_nif.o

# Sources - SDDL compiler (all .cpp except main.cpp)
SDDL_DIR = $(OPENZL_DIR)/tools/sddl/compiler
SDDL_SRCS = $(filter-out $(SDDL_DIR)/main.cpp, $(wildcard $(SDDL_DIR)/*.cpp))
SDDL_OBJS = $(patsubst $(SDDL_DIR)/%.cpp, c_src/sddl_%.o, $(SDDL_SRCS))

# SDDL profile and shared components libraries (built by CMake)
SDDL_PROFILE_LIB = $(OPENZL_BUILD_DIR)/custom_parsers/sddl/libsddl_profile.a
SHARED_COMPONENTS_LIB = $(OPENZL_BUILD_DIR)/custom_parsers/shared_components/libshared_components.a
OPENZL_CPP_LIB = $(OPENZL_BUILD_DIR)/cpp/libopenzl_cpp.a

.PHONY: all clean

all: $(PRIV_DIR) $(OPENZL_LIB) $(NIF_SO)

$(PRIV_DIR):
	mkdir -p $(PRIV_DIR)

# Build OpenZL static library via CMake (with SDDL profile enabled)
$(OPENZL_LIB):
	cmake -DCMAKE_BUILD_TYPE=Release \
		-DOPENZL_BUILD_TESTS=OFF \
		-DOPENZL_BUILD_BENCHMARKS=OFF \
		-DOPENZL_BUILD_CLI=OFF \
		-DOPENZL_BUILD_TOOLS=OFF \
		-DOPENZL_BUILD_EXAMPLES=OFF \
		-DOPENZL_BUILD_CUSTOM_PARSERS=ON \
		-S $(OPENZL_DIR) -B $(OPENZL_BUILD_DIR)
	cmake --build $(OPENZL_BUILD_DIR) -j$(shell nproc 2>/dev/null || sysctl -n hw.ncpu)

# Compile NIF source
$(NIF_OBJ): $(NIF_SRC)
	$(CXX) $(CXXFLAGS) -c -o $@ $<

# Compile SDDL compiler sources
c_src/sddl_%.o: $(SDDL_DIR)/%.cpp
	$(CXX) $(CXXFLAGS) -c -o $@ $<

# Link NIF shared library
$(NIF_SO): $(NIF_OBJ) $(SDDL_OBJS) $(OPENZL_LIB)
	$(CXX) $(LDFLAGS) -o $@ $(NIF_OBJ) $(SDDL_OBJS) $(SDDL_PROFILE_LIB) $(SHARED_COMPONENTS_LIB) $(OPENZL_CPP_LIB) $(OPENZL_LIB) $(OPENZL_ZSTD_LIB) $(OPENZL_LZ4_LIB)

clean:
	rm -f $(NIF_OBJ) $(SDDL_OBJS) $(NIF_SO)
	rm -rf $(OPENZL_BUILD_DIR)
