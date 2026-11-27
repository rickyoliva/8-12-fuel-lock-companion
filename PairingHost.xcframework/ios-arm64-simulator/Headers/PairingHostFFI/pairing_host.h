#ifndef PAIRING_HOST_H
#define PAIRING_HOST_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Logging spine
typedef void (*SILogCallback)(void *ctx, const char *msg);
int32_t si_log_init(SILogCallback cb, void *ctx);
void si_log_set_verbose(int32_t verbose);
void si_string_free(char *p);

// RPPairing host
typedef void (*SIPairReadyCb)(void *ctx,
                              const char *service_id,
                              uint16_t port,
                              const char *const *txt_keys,
                              const char *const *txt_vals,
                              size_t txt_count);

typedef void (*SIPairPinCb)(const char *pin, void *ctx);

typedef struct {
    char *error;
    char *device_name;
    char *device_model;
    char *device_udid;
    char *pairing_file_path;
    char *host_alt_irk_hex;
    char *device_address;
} SIPairResult;

typedef struct SIPairCancel SIPairCancel;

int32_t si_pairing_run_host(const char *bind_addr,
                            uint16_t port,
                            const char *name,
                            const char *model,
                            const char *out_path,
                            const char *host_alt_irk_hex,
                            const char *host_identifier,
                            SIPairReadyCb ready_cb,
                            SIPairPinCb pin_cb,
                            void *ctx,
                            const SIPairCancel *cancel,
                            SIPairResult *out);

void si_pairing_result_free(SIPairResult *r);
SIPairCancel *si_pairing_cancel_new(void);
void si_pairing_cancel(const SIPairCancel *cancel);
void si_pairing_cancel_free(SIPairCancel *cancel);

// Pairing port probe and discovery (49152-65535)
int32_t si_find_pairing_port(const char *device_ip,
                             const uint16_t *tried,
                             size_t tried_count,
                             uint16_t *out_port,
                             char **out_summary);

int32_t si_probe_pairing_port(const char *device_ip,
                              uint16_t port,
                              char **out_summary);

#ifdef __cplusplus
}
#endif

#endif // PAIRING_HOST_H
