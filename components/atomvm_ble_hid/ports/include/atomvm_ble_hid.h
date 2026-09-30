/*
 * SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
 */

#ifndef _ATOMVM_BLE_HID_H_
#define _ATOMVM_BLE_HID_H_

#include <context.h>
#include <globalcontext.h>
#include <term.h>

/* Registered as the "ble_hid" port driver; open with open_port({spawn, "ble_hid"}, Opts). */
void atomvm_ble_hid_init(GlobalContext *global);
Context *atomvm_ble_hid_create_port(GlobalContext *global, term opts);

#endif
