# Define default variables
OPENOCD         ?= openocd
OPENOCD_SCRIPTS ?= $(abspath $(dir $(shell which $(OPENOCD)))/../tcl)
GDB             ?= riscv64-unknown-elf-gdb
ADAPTER_SPEED   ?= 1000
INTERFACE       ?= ftdi
DEVICE          ?= olimex-arm-usb-ocd-h
ID              ?=
TARGET          ?= smp
PYTHON          ?= python

# OpenOCD ports
GDB_PORT    ?= 3334
TCL_PORT    ?= disabled
TELNET_PORT ?= disabled

export OPENOCD_SCRIPTS

SCRIPTS_DIR   ?= scripts

# Vivado variables
VIVADO        ?= vivado_lab
BITSTREAM     ?=
HW_TARGET     ?=

# CVA6 SDK variables
CVA6_SDK_DIR  ?= cva6-sdk
IMAGES_DIR    ?= $(CVA6_SDK_DIR)/install64
PAYLOAD       ?= $(IMAGES_DIR)/fw_payload.elf
DTB_FILE      ?= astral_vanilla_vcu118.dtb
DTB_ADDR      ?= 0x81800000

MEM_BASE_ADDR ?= 0x10000000

# Hyperram config
HYPERRAM_SIZE           ?= 0x2000000
HYPERRAM_LATENCY_ACCESS ?= 0x6
HYPERRAM_ADDRESS_SPACE  ?= 0
HYPPERAM_NO_OF_CHIPS    ?= 4
HYPERRAM_WHICH_PHY      ?= 0
HYPERRAM_PHYS_IN_USE    ?= 1
HYPERRAM_CFG_BASE_ADDR  ?= 0x1a101000
HYPERRAM_CFG_FILE       ?= generated/hyperram_config.cfg

OPENOCD_DEPS :=
GDB_DEPS     := $(PAYLOAD)

# Set NUM_HARTS and TARGET_FREQ
NUM_HARTS     ?= 1
TARGET_FREQ   ?= 50000000 # Hz

export NUM_HARTS TARGET_FREQ

# OpenOCD directory
OPENOCD_DIR   ?= openocd

# Initialize OpenOCD command arguments
OPENOCD_ARGS  = -s "$(OPENOCD_DIR)"

# Initialize OpenOCD commands
OPENOCD_CMDS   = -c "adapter speed $(ADAPTER_SPEED)" \
                 -c "set _INTERFACE $(INTERFACE)" \
                 -c "set _DEVICE $(DEVICE)" \
				 -c "gdb_port $(GDB_PORT)" \
				 -c "tcl_port $(TCL_PORT)" \
				 -c "telnet_port $(TELNET_PORT)"
ifneq ($(ID), )
	OPENOCD_CMDS +=  -c "adapter serial $(ID)"
endif

OPENOCD_CMDS  += -c "set _NUM_CORES $(NUM_HARTS)" \
                 -c "set _TARGET $(TARGET)" \
                 -f "openocd.cfg" \
                 -c "init" \
                 -c "reset halt"

# Use LLC in SPM mode (experimental)
ifeq ($(LLC_SPM), 1)
	OPENOCD_CMDS += -c "mww 0x10401000 0xffffffff"
	OPENOCD_CMDS += -c "mww 0x10401004 0xffffffff"
	OPENOCD_CMDS += -c "mww 0x10401010 0x1"
endif

# Conditional programming of Hyperram interface
ifeq ($(USE_HYPER),1)
	OPENOCD_CMDS += -f $(HYPERRAM_CFG_FILE)
	OPENOCD_DEPS += $(HYPERRAM_CFG_FILE)
	export USE_HYPER
endif

# Conditional load of DTB file
ifeq ($(PAYLOAD), $(IMAGES_DIR)/fw_payload.elf)
	GDB_DEPS += $(DTB_FILE)
endif

# Append OpenOCD commands to arguments
OPENOCD_ARGS += $(OPENOCD_CMDS)

$(HYPERRAM_CFG_FILE):
	mkdir -p $(dir $@)
	$(PYTHON) $(SCRIPTS_DIR)/hyperram_cfg.py \
		--hyperram_size             $(HYPERRAM_SIZE) \
		--hyperram_t_latency_access $(HYPERRAM_LATENCY_ACCESS) \
		--hypperam_no_of_chips      $(HYPPERAM_NO_OF_CHIPS) \
		--hyperram_which_phy        $(HYPERRAM_WHICH_PHY) \
		--hyperram_address_space    $(HYPERRAM_ADDRESS_SPACE) \
		--hyperram_phys_in_use      $(HYPERRAM_PHYS_IN_USE) \
		--hyperbus_cfg_base_addr    $(HYPERRAM_CFG_BASE_ADDR) \
		--memory_base_addr          $(MEM_BASE_ADDR) \
		--output_file               $@

# CVA6 SDK targets
.PHONY: $(CVA6_SDK_DIR)

$(CVA6_SDK_DIR):
	if [ ! -d "$(CVA6_SDK_DIR)/.git" ] || [ -z "$(shell ls -A $(CVA6_SDK_DIR))" ]; then \
		git submodule update --init --recursive $@; \
	fi

$(DTB_FILE): $(CVA6_SDK_DIR)
	make -C $(CVA6_SDK_DIR) $(notdir $@)

$(IMAGES_DIR)/fw_payload.elf: $(CVA6_SDK_DIR)
	make -C $(CVA6_SDK_DIR) images

.PHONY: load_bistream
load_bistream:
	$(VIVADO) -mode batch -source $(SCRIPTS_DIR)/load_bistream.tcl -tclargs $(BITSTREAM) $(HW_TARGET)

# Run OpenOCD to set up a GDB server
.PHONY: openocd
openocd: $(OPENOCD_DEPS)
	@echo "Interface      : $(INTERFACE)"
	@echo "Device         : $(DEVICE)"
	@echo "ID             : $(ID)"
	@echo "Number of cores: $(NUM_HARTS)"
	@echo "Target         : $(TARGET)"
	$(OPENOCD) $(OPENOCD_ARGS) -c "echo \"Ready for Remote Connections\""

# Run GDB to load the payload and execute it
.PHONY: gdb gdb-load-payload
gdb:
	$(GDB) \
	-ex "target extended-remote :$(GDB_PORT)"

gdb-load-payload:
	$(eval INITIAL_PC := $(shell LC_ALL=C riscv64-unknown-elf-objdump -f $(PAYLOAD) | awk '/start address/ {print $$NF}'))
	$(GDB) $(PAYLOAD) \
	-ex "target extended-remote :$(GDB_PORT)" \
	$(if $(filter $(IMAGES_DIR)/fw_payload.elf,$(PAYLOAD)), \
		-ex "monitor load_image $(DTB_FILE) $(DTB_ADDR)",) \
	$(foreach i, $(shell seq 1 $(NUM_HARTS)), -ex "thread $(i)" -ex "set \$$pc=$(INITIAL_PC)" -ex "info registers pc") \
	-ex "load"

gdb-load-payload-and-run:
	$(eval INITIAL_PC := $(shell LC_ALL=C riscv64-unknown-elf-objdump -f $(PAYLOAD) | awk '/start address/ {print $$NF}'))
	$(GDB) $(PAYLOAD) \
	-ex "target extended-remote :$(GDB_PORT)" \
	$(if $(filter $(IMAGES_DIR)/fw_payload.elf,$(PAYLOAD)), \
		-ex "monitor load_image $(DTB_FILE) $(DTB_ADDR)",) \
	$(foreach i, $(shell seq 1 $(NUM_HARTS)), -ex "thread $(i)" -ex "set \$$pc=$(INITIAL_PC)" -ex "info registers pc") \
	-ex "load" \
	-ex "continue"

.PHONY: boot-linux
boot-linux:
	$(eval INITIAL_PC := $(shell LC_ALL=C riscv64-unknown-elf-objdump -f $(PAYLOAD) | awk '/start address/ {print $$NF}'))
	$(GDB) $(PAYLOAD) \
	-ex "target extended-remote :$(GDB_PORT)" \
	-ex "monitor load_image $(DTB_FILE) $(DTB_ADDR)" \
	-ex "load" \
	-ex "thread 1" -ex "set \$$a0=0" -ex "set \$$a1=$(DTB_ADDR)" -ex "set \$$a2=0" \
	-ex "set \$$pc=$(INITIAL_PC)"  -ex "info registers pc"\


.PHONY: clean deep-clean
clean:
	make -C $(CVA6_SDK_DIR) clean
	make -C $(CVA6_SDK_DIR)/opensbi clean
	rm -f generated/* $(DTB_FILE) $(IMAGES_DIR)/*

deep-clean: clean
	make -C $(CVA6_SDK_DIR)/buildroot clean

.PHONY: init
init: $(CVA6_SDK_DIR)

init.%.gdb: %.h
	$(PYTHON) $(SCRIPTS_DIR)/header2gdb.py $< $@
