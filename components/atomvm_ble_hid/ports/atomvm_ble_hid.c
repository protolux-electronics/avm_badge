/*
 * SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
 */

/*
 * An AtomVM port driver that makes the chip a Bluetooth LE keyboard.
 *
 * NimBLE is the host, ESP-IDF's esp_hid builds the HID, battery and device
 * information services from the report map below, and this file owns the
 * GAP side: advertising, pairing with a passkey the owner types, bonding.
 *
 * NimBLE calls back on its own host task, so every owner message is built
 * on a temporary heap and posted with port_send_message_from_task. Commands
 * arrive as port:call/2 requests on the VM's scheduler.
 *
 * There is one Bluetooth stack, so there is at most one port. Its state lives
 * only in s_data, never in ctx->platform_data: a port killed with its owner
 * would have that freed under a still running stack. Opening a new port
 * while the stack is still up tears the old one down first.
 */

#include <sdkconfig.h>

#ifdef CONFIG_AVM_BLE_HID_ENABLE

#include <stdio.h>
#include <string.h>

#include <esp_heap_caps.h>
#include <esp_log.h>
#include <esp_mac.h>
#include <esp_random.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>

#include <esp_hid_common.h>
#include <esp_hidd.h>

#include <host/ble_gap.h>
#include <host/ble_gatt.h>
#include <host/ble_hs.h>
#include <host/ble_sm.h>
#include <host/ble_store.h>
#include <host/util/util.h>
#include <nimble/nimble_port.h>
#include <nimble/nimble_port_freertos.h>
#include <services/gap/ble_svc_gap.h>
#include <services/hid/ble_svc_hid.h>

#include <atom.h>
#include <context.h>
#include <defaultatoms.h>
#include <globalcontext.h>
#include <interop.h>
#include <mailbox.h>
#include <memory.h>
#include <port.h>
#include <term.h>
#include <utils.h>

#include <esp32_sys.h>

#include "atomvm_ble_hid.h"

#define TAG "atomvm_ble_hid"

/* Not exported by libAtomVM; the in-tree drivers each define it. */
#define PORT_REPLY_SIZE (TUPLE_SIZE(2) + REF_SIZE)

#define NAME_MAX_LEN 29
#define REPORT_LEN 8
#define KEYBOARD_REPORT_ID 1
#define KEYBOARD_MAP_INDEX 0
#define APPEARANCE_KEYBOARD 0x03C1
#define BATTERY_LEVEL 100
#define BATTERY_MAX 100
#define PASSKEY_MAX 999999
#define ADDR_LEN 6
#define DISCONNECT_WAIT_MS 1000

/* Flags, appearance and the HID UUID take 11 of the 31 advertising bytes. */
#define ADV_NAME_ROOM 18

/* NimBLE defines it in its store but declares it in no header. */
void ble_store_config_init(void);

static const char *const ble_hid_atom = ATOM_STR("\x7", "ble_hid");
static const char *const advertising_atom = ATOM_STR("\xB", "advertising");
static const char *const connected_atom = ATOM_STR("\x9", "connected");
static const char *const encrypted_atom = ATOM_STR("\x9", "encrypted");
static const char *const passkey_input_atom = ATOM_STR("\xD", "passkey_input");
static const char *const passkey_display_atom = ATOM_STR("\xF", "passkey_display");
static const char *const ready_atom = ATOM_STR("\x5", "ready");
static const char *const disconnected_atom = ATOM_STR("\xC", "disconnected");
/* The default ERROR_ATOM is a term; the posting helpers want the AtomString. */
static const char *const error_atom = ATOM_STR("\x5", "error");

static const char *const not_connected_atom = ATOM_STR("\xD", "not_connected");
static const char *const not_encrypted_atom = ATOM_STR("\xD", "not_encrypted");
static const char *const no_passkey_atom = ATOM_STR("\xA", "no_passkey");
static const char *const send_failed_atom = ATOM_STR("\xB", "send_failed");
static const char *const adv_failed_atom = ATOM_STR("\xA", "adv_failed");
static const char *const pairing_failed_atom = ATOM_STR("\xE", "pairing_failed");
static const char *const host_reset_atom = ATOM_STR("\xA", "host_reset");

/* option keys */
static const char *const owner_atom = ATOM_STR("\x5", "owner");
static const char *const name_atom = ATOM_STR("\x4", "name");

enum ble_hid_cmd
{
    BleHidInvalidCmd = 0,
    BleHidReportCmd,
    BleHidPasskeyCmd,
    BleHidForgetCmd,
    BleHidBatteryCmd,
    BleHidMemCmd,
    BleHidMemAtOpenCmd,
    BleHidCloseCmd
};

static const AtomStringIntPair cmd_table[] = {
    { ATOM_STR("\x6", "report"), BleHidReportCmd },
    { ATOM_STR("\x7", "passkey"), BleHidPasskeyCmd },
    { ATOM_STR("\x6", "forget"), BleHidForgetCmd },
    { ATOM_STR("\x7", "battery"), BleHidBatteryCmd },
    { ATOM_STR("\x3", "mem"), BleHidMemCmd },
    { ATOM_STR("\xB", "mem_at_open"), BleHidMemAtOpenCmd },
    { ATOM_STR("\x5", "close"), BleHidCloseCmd },
    SELECT_INT_DEFAULT(BleHidInvalidCmd)
};

/* Boot keyboard layout under report id 1: modifiers, reserved, six keys in; five LEDs out. */
static const uint8_t keyboard_report_map[] = {
    0x05, 0x01, /* Usage Page (Generic Desktop) */
    0x09, 0x06, /* Usage (Keyboard) */
    0xA1, 0x01, /* Collection (Application) */
    0x85, KEYBOARD_REPORT_ID, /* Report ID */
    0x05, 0x07, /*   Usage Page (Keyboard/Keypad) */
    0x19, 0xE0, /*   Usage Minimum (Left Control) */
    0x29, 0xE7, /*   Usage Maximum (Right GUI) */
    0x15, 0x00, /*   Logical Minimum (0) */
    0x25, 0x01, /*   Logical Maximum (1) */
    0x75, 0x01, /*   Report Size (1) */
    0x95, 0x08, /*   Report Count (8) */
    0x81, 0x02, /*   Input (Data, Variable, Absolute): modifiers */
    0x95, 0x01, /*   Report Count (1) */
    0x75, 0x08, /*   Report Size (8) */
    0x81, 0x03, /*   Input (Constant): reserved */
    0x95, 0x05, /*   Report Count (5) */
    0x75, 0x01, /*   Report Size (1) */
    0x05, 0x08, /*   Usage Page (LEDs) */
    0x19, 0x01, /*   Usage Minimum (Num Lock) */
    0x29, 0x05, /*   Usage Maximum (Kana) */
    0x91, 0x02, /*   Output (Data, Variable, Absolute): LEDs */
    0x95, 0x01, /*   Report Count (1) */
    0x75, 0x03, /*   Report Size (3) */
    0x91, 0x03, /*   Output (Constant): padding */
    0x95, 0x06, /*   Report Count (6) */
    0x75, 0x08, /*   Report Size (8) */
    0x15, 0x00, /*   Logical Minimum (0) */
    0x25, 0x65, /*   Logical Maximum (101) */
    0x05, 0x07, /*   Usage Page (Keyboard/Keypad) */
    0x19, 0x00, /*   Usage Minimum (0) */
    0x29, 0x65, /*   Usage Maximum (101) */
    0x81, 0x00, /*   Input (Data, Array, Absolute): keys */
    0xC0 /* End Collection */
};

static esp_hid_raw_report_map_t report_maps[] = {
    { .data = keyboard_report_map, .len = sizeof(keyboard_report_map) }
};

struct ble_hid_data
{
    GlobalContext *global;
    int32_t owner;
    int32_t port_pid;
    esp_hidd_dev_t *hid_dev;
    char name[NAME_MAX_LEN + 1];

    /* Guards the connection fields below, which the host task and the VM share. */
    SemaphoreHandle_t lock;
    /* Given by the disconnect callback while closing. */
    SemaphoreHandle_t gone;
    uint16_t conn_handle;
    bool connected;
    bool encrypted;
    bool bonded;
    bool subscribed;
    bool ready_sent;
    bool passkey_pending;
    bool closing;

    uint16_t report_handle;
    uint16_t boot_handle;

    size_t free_at_open;
    size_t largest_at_open;
};

static struct ble_hid_data *s_data = NULL;

static int gap_event(struct ble_gap_event *event, void *arg);

static inline void lock(struct ble_hid_data *data)
{
    xSemaphoreTake(data->lock, portMAX_DELAY);
}

static inline void unlock(struct ble_hid_data *data)
{
    xSemaphoreGive(data->lock);
}

static void post_event(struct ble_hid_data *data, Heap *heap, term event)
{
    GlobalContext *global = data->global;
    term port_term = term_from_local_process_id(data->port_pid);
    term msg = port_heap_create_tuple3(heap, globalcontext_make_atom(global, ble_hid_atom), port_term, event);
    port_send_message_from_task(global, term_from_local_process_id(data->owner), msg);
}

static void post_atom(struct ble_hid_data *data, AtomString event)
{
    BEGIN_WITH_STACK_HEAP(TUPLE_SIZE(3), heap);
    post_event(data, &heap, globalcontext_make_atom(data->global, event));
    END_WITH_STACK_HEAP(heap, data->global);
}

static void post_tagged(struct ble_hid_data *data, AtomString tag, term value)
{
    BEGIN_WITH_STACK_HEAP(TUPLE_SIZE(3) + TUPLE_SIZE(2), heap);
    term event = port_heap_create_tuple2(&heap, globalcontext_make_atom(data->global, tag), value);
    post_event(data, &heap, event);
    END_WITH_STACK_HEAP(heap, data->global);
}

static void post_error(struct ble_hid_data *data, AtomString reason)
{
    post_tagged(data, error_atom, globalcontext_make_atom(data->global, reason));
}

/* NimBLE keeps addresses least significant byte first; the owner gets them as printed. */
static void post_connected(struct ble_hid_data *data, const uint8_t *addr)
{
    uint8_t printed[ADDR_LEN];
    for (int i = 0; i < ADDR_LEN; i++) {
        printed[i] = addr[ADDR_LEN - 1 - i];
    }

    Heap heap;
    size_t size = TUPLE_SIZE(3) + TUPLE_SIZE(2) + term_binary_heap_size(ADDR_LEN);
    if (UNLIKELY(memory_init_heap(&heap, size) != MEMORY_GC_OK)) {
        ESP_LOGW(TAG, "No memory to report a connection");
        return;
    }

    term bin = term_from_literal_binary(printed, ADDR_LEN, &heap, data->global);
    term event = port_heap_create_tuple2(&heap, globalcontext_make_atom(data->global, connected_atom), bin);
    post_event(data, &heap, event);
    memory_destroy_heap_from_task(&heap, data->global);
}

static void start_advertising(struct ble_hid_data *data)
{
    struct ble_hs_adv_fields fields;
    struct ble_hs_adv_fields rsp;
    ble_uuid16_t hid_uuid = BLE_UUID16_INIT(BLE_SVC_HID_UUID16);
    size_t name_len = strlen(data->name);

    memset(&fields, 0, sizeof fields);
    memset(&rsp, 0, sizeof rsp);

    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.appearance = APPEARANCE_KEYBOARD;
    fields.appearance_is_present = 1;
    fields.uuids16 = &hid_uuid;
    fields.num_uuids16 = 1;
    fields.uuids16_is_complete = 1;

    /* A long name moves to the scan response rather than being cut short. */
    struct ble_hs_adv_fields *named = name_len <= ADV_NAME_ROOM ? &fields : &rsp;
    named->name = (uint8_t *) data->name;
    named->name_len = name_len;
    named->name_is_complete = 1;

    int rc = ble_gap_adv_set_fields(&fields);
    if (rc == 0 && named == &rsp) {
        rc = ble_gap_adv_rsp_set_fields(&rsp);
    }
    if (rc != 0) {
        ESP_LOGE(TAG, "Setting advertising data failed: %d", rc);
        post_error(data, adv_failed_atom);
        return;
    }

    struct ble_gap_adv_params params;
    memset(&params, 0, sizeof params);
    params.conn_mode = BLE_GAP_CONN_MODE_UND;
    params.disc_mode = BLE_GAP_DISC_MODE_GEN;
    params.itvl_min = BLE_GAP_ADV_ITVL_MS(30);
    params.itvl_max = BLE_GAP_ADV_ITVL_MS(50);

    rc = ble_gap_adv_start(BLE_OWN_ADDR_PUBLIC, NULL, BLE_HS_FOREVER, &params, gap_event, data);
    if (rc != 0 && rc != BLE_HS_EALREADY) {
        ESP_LOGE(TAG, "Advertising failed to start: %d", rc);
        post_error(data, adv_failed_atom);
        return;
    }

    post_atom(data, advertising_atom);
}

static bool closing(struct ble_hid_data *data)
{
    lock(data);
    bool value = data->closing;
    unlock(data);
    return value;
}

static void reset_connection(struct ble_hid_data *data)
{
    lock(data);
    data->connected = false;
    data->encrypted = false;
    data->bonded = false;
    data->subscribed = false;
    data->ready_sent = false;
    data->passkey_pending = false;
    data->conn_handle = BLE_HS_CONN_HANDLE_NONE;
    unlock(data);
}

/* Keys go out once the link is encrypted; a bonded host may never re-subscribe. */
static void maybe_ready(struct ble_hid_data *data)
{
    lock(data);
    bool ready = data->connected && data->encrypted && !data->ready_sent;
    if (ready) {
        data->ready_sent = true;
    }
    unlock(data);

    if (ready) {
        post_atom(data, ready_atom);
    }
}

static void on_passkey_action(struct ble_hid_data *data, struct ble_gap_event *event)
{
    struct ble_sm_io io;
    memset(&io, 0, sizeof io);

    switch (event->passkey.params.action) {
        case BLE_SM_IOACT_INPUT:
            lock(data);
            data->passkey_pending = true;
            unlock(data);
            post_atom(data, passkey_input_atom);
            break;

        case BLE_SM_IOACT_DISP:
            io.action = BLE_SM_IOACT_DISP;
            io.passkey = esp_random() % (PASSKEY_MAX + 1);
            ble_sm_inject_io(event->passkey.conn_handle, &io);
            post_tagged(data, passkey_display_atom, term_from_int(io.passkey));
            break;

        case BLE_SM_IOACT_NUMCMP:
            /* Accepting a comparison nobody saw would defeat MITM protection. */
            ESP_LOGW(TAG, "Rejecting numeric comparison");
            io.action = BLE_SM_IOACT_NUMCMP;
            io.numcmp_accept = 0;
            ble_sm_inject_io(event->passkey.conn_handle, &io);
            break;

        default:
            ESP_LOGW(TAG, "Unsupported pairing action %d", event->passkey.params.action);
            break;
    }
}

static int gap_event(struct ble_gap_event *event, void *arg)
{
    struct ble_hid_data *data = (struct ble_hid_data *) arg;
    struct ble_gap_conn_desc desc;

    switch (event->type) {
        case BLE_GAP_EVENT_CONNECT:
            if (event->connect.status != 0) {
                if (!closing(data)) {
                    start_advertising(data);
                }
                return 0;
            }

            lock(data);
            data->connected = true;
            data->conn_handle = event->connect.conn_handle;
            unlock(data);

            if (ble_gap_conn_find(event->connect.conn_handle, &desc) == 0) {
                post_connected(data, desc.peer_id_addr.val);
            }

            /* Pairs a new host, or re-encrypts with the stored key for a bonded one. */
            int rc = ble_gap_security_initiate(event->connect.conn_handle);
            if (rc != 0) {
                ESP_LOGW(TAG, "Security request failed: %d", rc);
            }
            return 0;

        case BLE_GAP_EVENT_DISCONNECT:
            ESP_LOGI(TAG, "Disconnected, reason %d", event->disconnect.reason);
            reset_connection(data);
            if (closing(data)) {
                /* esp_hid's listener ran before this callback, so its event is already queued. */
                xSemaphoreGive(data->gone);
            } else {
                post_atom(data, disconnected_atom);
                start_advertising(data);
            }
            return 0;

        case BLE_GAP_EVENT_ADV_COMPLETE: {
            lock(data);
            bool idle = !data->connected && !data->closing;
            unlock(data);
            if (idle) {
                start_advertising(data);
            }
            return 0;
        }

        case BLE_GAP_EVENT_ENC_CHANGE:
            if (event->enc_change.status != 0) {
                ESP_LOGW(TAG, "Encryption failed: %d", event->enc_change.status);
                post_error(data, pairing_failed_atom);
                return 0;
            }
            if (ble_gap_conn_find(event->enc_change.conn_handle, &desc) != 0) {
                return 0;
            }

            ESP_LOGI(TAG, "Encrypted %d, authenticated %d, bonded %d, key size %d",
                desc.sec_state.encrypted, desc.sec_state.authenticated, desc.sec_state.bonded,
                desc.sec_state.key_size);
            lock(data);
            data->encrypted = desc.sec_state.encrypted;
            data->bonded = desc.sec_state.bonded;
            data->passkey_pending = false;
            unlock(data);

            post_tagged(data, encrypted_atom, desc.sec_state.bonded ? TRUE_ATOM : FALSE_ATOM);
            maybe_ready(data);
            return 0;

        case BLE_GAP_EVENT_SUBSCRIBE:
            ESP_LOGI(TAG, "Subscribe attr %d notify %d reason %d", event->subscribe.attr_handle,
                event->subscribe.cur_notify, event->subscribe.reason);
            if (data->report_handle == 0 || event->subscribe.attr_handle == data->report_handle
                || event->subscribe.attr_handle == data->boot_handle) {
                lock(data);
                data->subscribed = event->subscribe.cur_notify;
                unlock(data);
            }
            return 0;

        case BLE_GAP_EVENT_PASSKEY_ACTION:
            on_passkey_action(data, event);
            return 0;

        case BLE_GAP_EVENT_REPEAT_PAIRING:
            /* The host lost its bond but this side kept it: drop ours and pair again. */
            if (ble_gap_conn_find(event->repeat_pairing.conn_handle, &desc) == 0) {
                ble_store_util_delete_peer(&desc.peer_id_addr);
            }
            return BLE_GAP_REPEAT_PAIRING_RETRY;

        default:
            return 0;
    }
}

static void on_sync(void)
{
    struct ble_hid_data *data = s_data;
    if (IS_NULL_PTR(data)) {
        return;
    }

    int rc = ble_hs_util_ensure_addr(0);
    if (rc != 0) {
        ESP_LOGE(TAG, "No public address: %d", rc);
        post_error(data, adv_failed_atom);
        return;
    }

    ble_uuid16_t svc = BLE_UUID16_INIT(BLE_SVC_HID_UUID16);
    ble_uuid16_t report = BLE_UUID16_INIT(BLE_SVC_HID_CHR_UUID16_RPT);
    ble_uuid16_t boot = BLE_UUID16_INIT(BLE_SVC_HID_CHR_UUID16_BOOT_KBD_INP);
    uint16_t handle;

    /* The keyboard input is the first report characteristic in the service. */
    if (ble_gatts_find_chr(&svc.u, &report.u, NULL, &handle) == 0) {
        data->report_handle = handle;
    }
    if (ble_gatts_find_chr(&svc.u, &boot.u, NULL, &handle) == 0) {
        data->boot_handle = handle;
    }

    start_advertising(data);
}

static void on_reset(int reason)
{
    ESP_LOGE(TAG, "NimBLE host reset: %d", reason);
    if (!IS_NULL_PTR(s_data)) {
        reset_connection(s_data);
        post_error(s_data, host_reset_atom);
    }
}

static void host_task(void *param)
{
    UNUSED(param);
    nimble_port_run();
    nimble_port_freertos_deinit();
}

/*
 * The reverse of start_stack; the host task has stopped when nimble_port_stop
 * returns. False when it did not stop, and the data must then stay allocated.
 */
static bool stop_stack(struct ble_hid_data *data)
{
    lock(data);
    data->closing = true;
    unlock(data);

    ble_gap_adv_stop();

    lock(data);
    bool connected = data->connected;
    uint16_t conn = data->conn_handle;
    unlock(data);
    if (connected) {
        xSemaphoreTake(data->gone, 0);
        if (ble_gap_terminate(conn, BLE_ERR_REM_USER_CONN_TERM) == 0
            && xSemaphoreTake(data->gone, pdMS_TO_TICKS(DISCONNECT_WAIT_MS)) != pdTRUE) {
            ESP_LOGW(TAG, "No disconnect within %d ms", DISCONNECT_WAIT_MS);
        }
    }

    if (!IS_NULL_PTR(data->hid_dev)) {
        esp_hidd_dev_deinit(data->hid_dev);
        data->hid_dev = NULL;
    }

    if (nimble_port_stop() != 0) {
        ESP_LOGE(TAG, "nimble_port_stop failed; the stack stays up");
        return false;
    }
    /* esp_hid already ran ble_gatts_stop, which frees the GATT server's state block;
     * ble_hs_deinit runs it again and would read through the NULL. A reset re-creates the block. */
    ble_gatts_reset();
    nimble_port_deinit();
    return true;
}

static void free_data(struct ble_hid_data *data)
{
    if (s_data == data) {
        s_data = NULL;
    }
    if (!IS_NULL_PTR(data->lock)) {
        vSemaphoreDelete(data->lock);
    }
    if (!IS_NULL_PTR(data->gone)) {
        vSemaphoreDelete(data->gone);
    }
    free(data);
}

/* The stack this port opened, or NULL once it was closed or replaced. */
static struct ble_hid_data *port_data(Context *ctx)
{
    struct ble_hid_data *data = s_data;
    return (!IS_NULL_PTR(data) && data->port_pid == ctx->process_id) ? data : NULL;
}

static esp_err_t start_stack(struct ble_hid_data *data)
{
    esp_err_t err = nimble_port_init();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "nimble_port_init failed: %s", esp_err_to_name(err));
        return err;
    }

    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.reset_cb = on_reset;
    ble_hs_cfg.store_status_cb = ble_store_util_status_rr;
    ble_hs_cfg.sm_io_cap = BLE_SM_IO_CAP_KEYBOARD_ONLY;
    ble_hs_cfg.sm_bonding = 1;
    ble_hs_cfg.sm_mitm = 1;
    ble_hs_cfg.sm_sc = 1;
    ble_hs_cfg.sm_our_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.sm_their_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;

    esp_hid_device_config_t config = {
        .vendor_id = 0x16C0,
        .product_id = 0x05DF,
        .version = 0x0100,
        .device_name = data->name,
        .manufacturer_name = "AtomVM",
        .serial_number = "0001",
        .report_maps = report_maps,
        .report_maps_len = 1
    };

    /* esp_hid chains on to the sync and reset callbacks set above. */
    err = esp_hidd_dev_init(&config, ESP_HID_TRANSPORT_BLE, NULL, &data->hid_dev);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "esp_hidd_dev_init failed: %s", esp_err_to_name(err));
        nimble_port_deinit();
        return err;
    }
    /* Until the owner reports a reading. */
    esp_hidd_dev_battery_set(data->hid_dev, BATTERY_LEVEL);

    ble_svc_gap_device_name_set(data->name);
    ble_svc_gap_device_appearance_set(APPEARANCE_KEYBOARD);

    ble_store_config_init();

    nimble_port_freertos_init(host_task);

    return ESP_OK;
}

static term do_report(Context *ctx, struct ble_hid_data *data, term req)
{
    term report = term_get_tuple_element(req, 1);
    if (!term_is_binary(report) || term_binary_size(report) != REPORT_LEN) {
        return BADARG_ATOM;
    }

    lock(data);
    bool connected = data->connected;
    bool encrypted = data->encrypted;
    unlock(data);

    if (!connected) {
        return port_create_error_tuple(ctx, globalcontext_make_atom(ctx->global, not_connected_atom));
    }
    if (!encrypted) {
        return port_create_error_tuple(ctx, globalcontext_make_atom(ctx->global, not_encrypted_atom));
    }

    uint8_t bytes[REPORT_LEN];
    memcpy(bytes, term_binary_data(report), REPORT_LEN);

    esp_err_t err = esp_hidd_dev_input_set(data->hid_dev, KEYBOARD_MAP_INDEX, KEYBOARD_REPORT_ID, bytes, REPORT_LEN);
    if (err != ESP_OK) {
        return port_create_error_tuple(ctx, globalcontext_make_atom(ctx->global, send_failed_atom));
    }

    return OK_ATOM;
}

static term do_passkey(Context *ctx, struct ble_hid_data *data, term req)
{
    term value = term_get_tuple_element(req, 1);
    if (!term_is_integer(value) || term_to_int(value) < 0 || term_to_int(value) > PASSKEY_MAX) {
        return BADARG_ATOM;
    }

    lock(data);
    bool pending = data->passkey_pending;
    uint16_t conn = data->conn_handle;
    unlock(data);

    if (!pending) {
        return port_create_error_tuple(ctx, globalcontext_make_atom(ctx->global, no_passkey_atom));
    }

    struct ble_sm_io io;
    memset(&io, 0, sizeof io);
    io.action = BLE_SM_IOACT_INPUT;
    io.passkey = term_to_int(value);

    int rc = ble_sm_inject_io(conn, &io);
    if (rc != 0) {
        ESP_LOGW(TAG, "ble_sm_inject_io failed: %d", rc);
        return port_create_error_tuple(ctx, globalcontext_make_atom(ctx->global, pairing_failed_atom));
    }

    lock(data);
    data->passkey_pending = false;
    unlock(data);

    return OK_ATOM;
}

/* The Battery Service level; the host is notified of a change if it listens. */
static term do_battery(Context *ctx, struct ble_hid_data *data, term req)
{
    term value = term_get_tuple_element(req, 1);
    if (!term_is_integer(value) || term_to_int(value) < 0 || term_to_int(value) > BATTERY_MAX) {
        return BADARG_ATOM;
    }

    if (esp_hidd_dev_battery_set(data->hid_dev, (uint8_t) term_to_int(value)) != ESP_OK) {
        return port_create_error_tuple(ctx, globalcontext_make_atom(ctx->global, send_failed_atom));
    }

    return OK_ATOM;
}

/* Advertising carries on, or restarts when the disconnect lands. */
static term do_forget(struct ble_hid_data *data)
{
    ble_store_clear();

    lock(data);
    bool connected = data->connected;
    uint16_t conn = data->conn_handle;
    unlock(data);

    if (connected) {
        ble_gap_terminate(conn, BLE_ERR_REM_USER_CONN_TERM);
    }

    return OK_ATOM;
}

static term mem_tuple(Context *ctx, size_t free_bytes, size_t largest)
{
    return port_create_tuple3(ctx, OK_ATOM, term_from_int(free_bytes), term_from_int(largest));
}

static NativeHandlerResult consume_mailbox(Context *ctx)
{
    GlobalContext *global = ctx->global;
    bool closed = false;

    while (mailbox_has_next(&ctx->mailbox)) {
        Message *message = mailbox_first(&ctx->mailbox);
        term msg = message->message;

        GenMessage gen_message;
        if (UNLIKELY(port_parse_gen_message(msg, &gen_message) != GenCallMessage)) {
            ESP_LOGW(TAG, "Received a message that is not a call");
            mailbox_remove_message(&ctx->mailbox, &ctx->heap);
            continue;
        }

        struct ble_hid_data *data = port_data(ctx);
        term req = gen_message.req;
        term cmd_term = term_is_tuple(req) ? term_get_tuple_element(req, 0) : req;
        int cmd = interop_atom_term_select_int(cmd_table, cmd_term, global);

        /* Room for the reply and the largest tuple a command builds. */
        port_ensure_available(ctx, PORT_REPLY_SIZE + TUPLE_SIZE(3));

        term reply;
        if (IS_NULL_PTR(data) || closed) {
            /* Superseded by a newer port, or already closed. */
            reply = port_create_error_tuple(ctx, NOPROC_ATOM);
            closed = true;
        } else {
            bool arity2 = term_is_tuple(req) && term_get_tuple_arity(req) == 2;

            switch (cmd) {
                case BleHidReportCmd:
                    reply = arity2 ? do_report(ctx, data, req) : BADARG_ATOM;
                    break;

                case BleHidPasskeyCmd:
                    reply = arity2 ? do_passkey(ctx, data, req) : BADARG_ATOM;
                    break;

                case BleHidForgetCmd:
                    reply = do_forget(data);
                    break;

                case BleHidBatteryCmd:
                    reply = arity2 ? do_battery(ctx, data, req) : BADARG_ATOM;
                    break;

                case BleHidMemCmd:
                    reply = mem_tuple(ctx, heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
                        heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL));
                    break;

                case BleHidMemAtOpenCmd:
                    reply = mem_tuple(ctx, data->free_at_open, data->largest_at_open);
                    break;

                case BleHidCloseCmd:
                    if (stop_stack(data)) {
                        free_data(data);
                    }
                    reply = OK_ATOM;
                    closed = true;
                    break;

                default:
                    ESP_LOGW(TAG, "Unrecognised command");
                    reply = BADARG_ATOM;
                    break;
            }
        }

        port_send_reply(ctx, gen_message.pid, gen_message.ref, reply);
        mailbox_remove_message(&ctx->mailbox, &ctx->heap);
    }

    return closed ? NativeTerminate : NativeContinue;
}

void atomvm_ble_hid_init(GlobalContext *global)
{
    UNUSED(global);
}

/* Default: "Badge " and the last two bytes of the factory MAC in hex. */
static void default_name(char *out)
{
    uint8_t mac[ADDR_LEN] = { 0 };
    esp_efuse_mac_get_default(mac);
    snprintf(out, NAME_MAX_LEN + 1, "Badge %02X%02X", mac[4], mac[5]);
}

Context *atomvm_ble_hid_create_port(GlobalContext *global, term opts)
{
    term owner = interop_kv_get_value(opts, owner_atom, global);
    if (UNLIKELY(!term_is_pid(owner))) {
        ESP_LOGE(TAG, "Missing owner pid");
        return NULL;
    }

    /* One stack, one port: a port whose owner never closed it gives way. */
    if (!IS_NULL_PTR(s_data)) {
        ESP_LOGW(TAG, "Replacing a port that was never closed");
        struct ble_hid_data *stale = s_data;
        if (!stop_stack(stale)) {
            return NULL;
        }
        free_data(stale);
    }

    struct ble_hid_data *data = calloc(1, sizeof(struct ble_hid_data));
    if (IS_NULL_PTR(data)) {
        return NULL;
    }

    data->lock = xSemaphoreCreateMutex();
    data->gone = xSemaphoreCreateBinary();
    if (IS_NULL_PTR(data->lock) || IS_NULL_PTR(data->gone)) {
        free_data(data);
        return NULL;
    }

    data->free_at_open = heap_caps_get_free_size(MALLOC_CAP_INTERNAL);
    data->largest_at_open = heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL);
    data->global = global;
    data->owner = term_to_local_process_id(owner);
    data->conn_handle = BLE_HS_CONN_HANDLE_NONE;

    term name = interop_kv_get_value(opts, name_atom, global);
    if (term_is_string(name) || term_is_binary(name)) {
        int ok;
        char *str = interop_term_to_string(name, &ok);
        if (ok && !IS_NULL_PTR(str) && str[0] != '\0') {
            strncpy(data->name, str, NAME_MAX_LEN);
            data->name[NAME_MAX_LEN] = '\0';
        }
        free(str);
    }
    if (data->name[0] == '\0') {
        default_name(data->name);
    }

    Context *ctx = context_new(global);
    ctx->native_handler = consume_mailbox;
    data->port_pid = ctx->process_id;

    s_data = data;

    if (start_stack(data) != ESP_OK) {
        ESP_LOGE(TAG, "Internal RAM at open: %u free, largest block %u",
            (unsigned) data->free_at_open, (unsigned) data->largest_at_open);
        heap_caps_print_heap_info(MALLOC_CAP_INTERNAL | MALLOC_CAP_DMA);
        free_data(data);
        context_destroy(ctx);
        return NULL;
    }

    ESP_LOGI(TAG, "Advertising as \"%s\"", data->name);

    return ctx;
}

REGISTER_PORT_DRIVER(ble_hid, atomvm_ble_hid_init, NULL, atomvm_ble_hid_create_port)

#endif
