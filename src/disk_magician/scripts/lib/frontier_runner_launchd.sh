#!/usr/bin/env bash

frontier_root_runner_kickstart() {
  # Without -k launchd leaves an already-running service untouched.
  launchctl kickstart system/com.jleechanorg.disk-magician-frontier-root
}

frontier_root_runner_after_bootstrap() {
  [[ "${1:-false}" == true ]] || return 0
  frontier_root_runner_kickstart
}

frontier_root_runner_after_bootstrap() {
  [[ "${1:-false}" == true ]] || return 0
  frontier_root_runner_kickstart
}
