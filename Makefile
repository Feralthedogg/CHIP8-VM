CC       := x86_64-w64-mingw32-gcc
ASMFLAGS := -x assembler -c
LDFLAGS  := -lgdi32 -luser32 -lkernel32 -lwinmm

TARGET   := chip8.exe
OBJS     := chip8.o cdp1802.o

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(OBJS) -o $(TARGET) $(LDFLAGS)

%.o: %.asm
	$(CC) $(ASMFLAGS) $< -o $@

clean:
	rm -f $(OBJS) $(TARGET)
