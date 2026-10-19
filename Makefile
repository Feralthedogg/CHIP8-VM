CC       := x86_64-w64-mingw32-gcc
ASMFLAGS := -x assembler -c
LDFLAGS  := -lgdi32 -luser32 -lkernel32 -lwinmm
PYTHON   ?= python3
NM       := x86_64-w64-mingw32-nm

TARGET   := chip8.exe
OBJS     := chip8.o cdp1802.o

.PHONY: all test test-core test-roms clean

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(OBJS) -o $(TARGET) $(LDFLAGS)

%.o: %.asm
	$(CC) $(ASMFLAGS) $< -o $@

test: $(TARGET)
	NM="$(NM)" $(PYTHON) -m unittest discover -s tests -v

test-core: $(TARGET)
	NM="$(NM)" $(PYTHON) -m unittest discover -s tests -p test_core.py -v

test-roms: $(TARGET)
	NM="$(NM)" $(PYTHON) -m unittest discover -s tests -p test_timendus.py -v

clean:
	rm -f $(OBJS) $(TARGET)
