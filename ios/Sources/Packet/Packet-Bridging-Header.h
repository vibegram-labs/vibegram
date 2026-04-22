#ifndef VibePacketBridgingHeader_h
#define VibePacketBridgingHeader_h

#include <stdint.h>

void phantom_set_log_callback(void (*cb)(const char *));
char *phantom_copy_mesh_stats_json(void);
void phantom_free_string(char *value);
void phantom_stop_client(void);
int32_t phantom_start_mesh(const char *config_json, uint16_t listen_port);
int32_t phantom_import_mesh_peers(const char *peers_json);

#endif /* VibePacketBridgingHeader_h */
