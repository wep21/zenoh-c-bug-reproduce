package main

/*
#include "zenoh.h"

// Wrapper so cgo calls a real zenoh-c function (pulls the symbol from libzenohc).
static int zenoh_config_roundtrip(void) {
  z_owned_config_t config;
  if (z_config_default(&config) != Z_OK) {
    return 1;
  }
  z_config_drop(z_config_move(&config));
  return 0;
}
*/
import "C"

import (
	"fmt"
	"os"
)

func main() {
	if C.zenoh_config_roundtrip() != 0 {
		fmt.Fprintln(os.Stderr, "z_config_default failed")
		os.Exit(1)
	}
	fmt.Println("go: zenoh-c OK")
}
