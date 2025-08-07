import re
import sys

def extract_memory_writes(header_file):
    pattern = re.compile(r'\(\*\(volatile unsigned int \*\)\(uint64_t\)\((0x[0-9A-Fa-f]+)\)\) = (0x[0-9A-Fa-f]+) *;')
    gdb_commands = []

    with open(header_file, 'r') as file:
        for line in file:
            match = pattern.search(line)
            if match:
                addr = match.group(1)
                val = match.group(2)
                gdb_commands.append(f"set {{unsigned int}}{addr} = {val}")

    return gdb_commands

def write_gdb_init_file(commands, output_file):
    with open(output_file, 'w') as file:
        for cmd in commands:
            file.write(cmd + '\n')

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Uso: python extract_gdb_init.py input_file.h output_file.gdb")
        sys.exit(1)

    input_file = sys.argv[1]
    output_file = sys.argv[2]

    gdb_cmds = extract_memory_writes(input_file)
    write_gdb_init_file(gdb_cmds, output_file)
    print(f"{len(gdb_cmds)} comandi estratti e scritti in {output_file}")
