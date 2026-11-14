// Calls a real zenoh-c function so the linker must pull the symbol from
// libzenohc (.a or .so). Otherwise "no NEEDED entry" would prove nothing.
#include <stdio.h>

#include "zenoh.h"

int main(void) {
  z_owned_config_t config;
  if (z_config_default(&config) != Z_OK) {
    fprintf(stderr, "z_config_default failed\n");
    return 1;
  }
  z_config_drop(z_config_move(&config));
  printf("c: zenoh-c OK\n");
  return 0;
}
