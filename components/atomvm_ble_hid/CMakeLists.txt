#
# SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
#

set(ATOMVM_BLE_HID_COMPONENT_SRCS
    "ports/atomvm_ble_hid.c"
)

# WHOLE_ARCHIVE keeps the port driver's registration record from being dropped
# by the linker: nothing in the VM references it by name.
if(IDF_VERSION_MAJOR GREATER_EQUAL 5)
    set(OPTIONAL_WHOLE_ARCHIVE WHOLE_ARCHIVE)
else()
    set(OPTIONAL_WHOLE_ARCHIVE "")
endif()

idf_component_register(
    SRCS ${ATOMVM_BLE_HID_COMPONENT_SRCS}
    INCLUDE_DIRS "ports/include"
    PRIV_REQUIRES "libatomvm" "avm_sys" "bt" "esp_hid" "nvs_flash"
    ${OPTIONAL_WHOLE_ARCHIVE}
)
