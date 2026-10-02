# =========================================================
# Makefile - Proyecto: Normalizador estadistico vectorizado
# =========================================================

CC        := gcc
NASM      := nasm
CFLAGS    := -std=gnu11 -Wall -Wextra -O2 -g
NASMFLAGS := -f elf64 -g -F dwarf
LDFLAGS   := -lm

SRC_DIR    := src
INC_DIR    := include
ASM_SCALAR := asm/scalar/stats_scalar.asm
ASM_VECTOR := asm/vector/stats_vector.asm
OBJ_DIR    := obj
BIN_DIR    := bin

DRIVER_OBJ := $(OBJ_DIR)/driver.o
SCALAR_OBJ := $(OBJ_DIR)/stats_scalar.o
VECTOR_OBJ := $(OBJ_DIR)/stats_vector.o

.PHONY: all clean run-scalar run-vector dirs

all: dirs $(BIN_DIR)/norm_scalar $(BIN_DIR)/norm_vector

dirs:
	@mkdir -p $(OBJ_DIR) $(BIN_DIR) data

$(BIN_DIR)/norm_scalar: $(DRIVER_OBJ) $(SCALAR_OBJ)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

$(BIN_DIR)/norm_vector: $(DRIVER_OBJ) $(VECTOR_OBJ)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

$(DRIVER_OBJ): $(SRC_DIR)/driver.c $(INC_DIR)/stats.h | dirs
	$(CC) $(CFLAGS) -I$(INC_DIR) -c $< -o $@

$(SCALAR_OBJ): $(ASM_SCALAR) | dirs
	$(NASM) $(NASMFLAGS) $< -o $@

$(VECTOR_OBJ): $(ASM_VECTOR) | dirs
	$(NASM) $(NASMFLAGS) $< -o $@

# Atajos de conveniencia (requieren haber generado data/input.dat)
run-scalar: $(BIN_DIR)/norm_scalar
	./$(BIN_DIR)/norm_scalar data/input.dat data/output_scalar.dat 10

run-vector: $(BIN_DIR)/norm_vector
	./$(BIN_DIR)/norm_vector data/input.dat data/output_vector.dat 10

clean:
	rm -rf $(OBJ_DIR) $(BIN_DIR)
